// ============================================================
// cmark.c — FOGCCC: C 标记基准
//   用法:  ./cmark [maxN] [trials] [avg_refs]      默认 4096 8 2
// 交叉编译:
//   arm-*-gcc -O2 -static -o cmark cmark.c
// ============================================================
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define REG_BASE   0x43C00000u
#define GRAPH_BASE 0x1E000000u
#define GRAPH_SIZE 0x100000u          /* 1 MiB */
#define HDR_BASE   0x0000u
#define N_MAX      4096u

#define R_CTRL 0x00u
#define R_OBJ_BASE 0x04u
#define R_OBJ_COUNT 0x08u
#define R_ROOT_COUNT 0x0Cu
#define R_MARKED 0x10u
#define R_CYCLES 0x14u
#define R_Q_TAIL 0x1Cu
#define R_ROOT_LIST 0x40u

#define CTRL_START 1u
#define CTRL_CLEAR_Q 4u

static uint8_t  *gbase;              /* 映射到的图基址 */
static volatile uint32_t *regs;

/* ---- 图构造用 ---- */
static uint32_t parent_of[N_MAX];
static uint32_t child_cnt[N_MAX];
static uint32_t extra_cnt[N_MAX];
static uint32_t ref_off[N_MAX];      /* 引用数组相对 GRAPH_BASE 的字节偏移 */
static uint32_t ref_cnt[N_MAX];
static uint32_t wcur[N_MAX];         /* 写游标(字节偏移) */

/* ---- 标记用 ---- */
static uint8_t  marked[N_MAX];
static uint32_t queue_[N_MAX];
static uint8_t  cbuf[GRAPH_SIZE];    /* 缓存版副本 */

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

/* ============================================================
 * 造图: 与 gc_test.py 同规则 (spanning tree + extra + garbage)
 * 返回 live 区大小 L
 * ============================================================ */
static uint32_t build_graph(uint32_t n, int avg_refs, uint32_t *used_bytes) {
    uint32_t L = (n * 3u) / 4u;
    uint32_t i, k, cur;

    for (i = 0; i < n; i++) { child_cnt[i] = 0; extra_cnt[i] = 0; }

    /* live: 生成树 —— 保证从 0 可达 */
    for (i = 1; i < L; i++) {
        uint32_t p = (uint32_t)(rand() % (int)i);
        parent_of[i] = p;
        child_cnt[p]++;
    }
    /* live: 额外随机边 */
    for (i = 0; i < L; i++)
        extra_cnt[i] = (uint32_t)(rand() % (avg_refs + 1));
    /* garbage: 边只落在 [L,n) 内部 */
    for (i = L; i < n; i++)
        extra_cnt[i] = (uint32_t)(rand() % (avg_refs * 2 + 1));

    /* 引用数 + 偏移 */
    cur = (HDR_BASE + n * 16u + 0xFFFu) & ~0xFFFu;
    for (i = 0; i < n; i++) {
        uint32_t rc = extra_cnt[i] + child_cnt[i] + (i ? 1u : 0u);
        ref_cnt[i] = rc;
        ref_off[i] = cur;
        cur += rc * 4u + 4u;
    }
    if (cur > GRAPH_SIZE) { fprintf(stderr, "ERROR: graph too large %u\n", cur); exit(1); }
    *used_bytes = cur;

    memset(gbase, 0, cur);
    /* 头 */
    for (i = 0; i < n; i++) {
        uint32_t *h = (uint32_t *)(gbase + HDR_BASE + i * 16u);
        h[0] = i;
        h[1] = ref_cnt[i];
        h[2] = GRAPH_BASE + ref_off[i];
        h[3] = 0;
    }
    /* 引用数组 (顺序无所谓) */
    for (i = 0; i < n; i++) wcur[i] = ref_off[i];
    /* 树边 (双向) */
    for (i = 1; i < L; i++) {
        uint32_t p = parent_of[i];
        *(uint32_t *)(gbase + wcur[p]) = i;        wcur[p] += 4;
        *(uint32_t *)(gbase + wcur[i]) = p;        wcur[i] += 4;
    }
    /* 额外边 */
    for (i = 0; i < n; i++) {
        for (k = 0; k < extra_cnt[i]; k++) {
            uint32_t x;
            if (i < L) { x = (uint32_t)(rand() % (int)L); if (x == i) x = (x + 1u) % L; }
            else       { uint32_t g = n - L; x = g ? (L + (uint32_t)(rand() % (int)g)) : L;
                         if (x == i) x = L + ((x - L + 1u) % (g ? g : 1u)); }
            *(uint32_t *)(gbase + wcur[i]) = x;    wcur[i] += 4;
        }
        *(uint32_t *)(gbase + wcur[i]) = 0xFFFFFFFFu;   /* 终止符 */
    }
    return L;
}

/* ============================================================
 * C 标记: base 是图的起始字节地址, ref_ptr_mode:
 *   0 = 头部 h[2] 为物理地址, 需减去 GRAPH_BASE
 *   1 = 头部 h[2] 已为本缓冲区内的地址
 * 返回标记数
 * ============================================================ */
static uint32_t c_mark(uint32_t n, const uint8_t *base, int already_fixed) {
    uint32_t head = 0, tail = 0, i;

    memset(marked, 0, n);
    marked[0] = 1;
    queue_[tail++] = 0;

    while (head < tail) {
        uint32_t c = queue_[head++];
        const uint32_t *h = (const uint32_t *)(base + HDR_BASE + c * 16u);
        uint32_t rc = h[1];
        const uint32_t *refs;
        if (already_fixed) refs = (const uint32_t *)(uintptr_t)h[2];
        else               refs = (const uint32_t *)(base + (h[2] - GRAPH_BASE));
        for (i = 0; i < rc; i++) {
            uint32_t x = refs[i];
            if (x == 0xFFFFFFFFu) break;
            if (x < n && !marked[x]) { marked[x] = 1; queue_[tail++] = x; }
        }
    }
    return tail;
}
static void c_prepare_cached(uint32_t n, uint32_t used) {
    uint32_t i;
    memcpy(cbuf, gbase, used);
    for (i = 0; i < n; i++) {
        uint32_t *h = (uint32_t *)(cbuf + HDR_BASE + i * 16u);
        h[2] = (uint32_t)(uintptr_t)(cbuf + (h[2] - GRAPH_BASE));
    }
}

/* ============================================================
 * 跑一次 FPGA 引擎, 返回 1 成功; cycles/marked 输出
 * ============================================================ */
static int hw_run(uint32_t n, uint32_t *cycles, uint32_t *mkd) {
    uint32_t cyc0, t0;

    regs[R_ROOT_LIST / 4] = 0;              /* roots = {0} */
    regs[R_ROOT_COUNT / 4] = 1;
    regs[R_OBJ_BASE / 4]   = GRAPH_BASE;
    regs[R_OBJ_COUNT / 4]  = n;
    regs[R_CTRL / 4]       = CTRL_CLEAR_Q;
    usleep(2000);

    cyc0 = regs[R_CYCLES / 4];
    regs[R_CTRL / 4] = CTRL_START;
    /* 完成判据 = CYCLES 变化 (只有 S_DONE 会锁存它) */
    for (t0 = 0; t0 < 3000000u; t0++) {
        if (regs[R_CYCLES / 4] != cyc0) {
            *cycles = regs[R_CYCLES / 4];
            *mkd    = regs[R_MARKED / 4];
            return 1;
        }
    }
    *cycles = 0; *mkd = 0;
    return 0;
}

int main(int argc, char **argv) {
    uint32_t maxN = (argc > 1) ? (uint32_t)atoi(argv[1]) : 4096u;
    int trials    = (argc > 2) ? atoi(argv[2]) : 8;
    int avg_refs  = (argc > 3) ? atoi(argv[3]) : 2;
    int fd, t;
    double tot_hw = 0, tot_cu = 0, tot_cc = 0;
    uint32_t tot_l = 0;

    if (maxN > N_MAX) maxN = N_MAX;
    if (avg_refs < 1) avg_refs = 1;

    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem (need root)"); return 1; }
    regs = (volatile uint32_t *)mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                                     MAP_SHARED, fd, REG_BASE);
    gbase = (uint8_t *)mmap(NULL, GRAPH_SIZE, PROT_READ | PROT_WRITE,
                            MAP_SHARED, fd, GRAPH_BASE);
    if (regs == MAP_FAILED || gbase == MAP_FAILED) { perror("mmap"); return 1; }

    printf("======================================================================\n");
    printf(" FOGCCC  C-mark baseline   maxN=%u  trials=%d  avg_refs=%d\n", maxN, trials, avg_refs);
    printf(" graph @ 0x%08X   regs @ 0x%08X\n", GRAPH_BASE, REG_BASE);
    printf(" C-uncached = same uncached DDR path as the PL engine (fairest)\n");
    printf(" C-cached   = heap copy, what an in-process GC would see (CPU upper bound)\n");
    printf("======================================================================\n");

    srand(42);                              /* 固定种子, 可复现 */

    printf(" %5s %6s %6s %8s %12s %10s %10s %9s %8s %9s  %s\n",
           "trial", "N", "L", "garb", "HW cyc", "HW us", "C-unc us",
           "HW/Cun", "C-cac us", "HW/Cca", "mkd(HW/Cu/Cc)");
    printf(" %s\n", "--------------------------------------------------------------------------------------------");

    for (t = 1; t <= trials; t++) {
        uint32_t lo = maxN / 8u; if (lo < 64u) lo = 64u;
        uint32_t n  = lo + (uint32_t)(rand() % (int)(maxN - lo + 1u));
        uint32_t used, L, hw_cyc = 0, hw_mkd = 0;
        double t0, cu, cc;
        uint32_t mku, mkc;

        L = build_graph(n, avg_refs, &used);
        usleep(20000);                      /* 让写入落盘 (和 Python 版一致) */

        if (!hw_run(n, &hw_cyc, &hw_mkd)) { printf(" trial %d: HW TIMEOUT\n", t); continue; }

        t0 = now_ms(); mku = c_mark(n, gbase, 0);        cu = now_ms() - t0;
        c_prepare_cached(n, used);                       /* 拷图+修指针: 不计时 */
        t0 = now_ms(); mkc = c_mark(n, cbuf, 1);         cc = now_ms() - t0;   /* 只计标记 */

        {
            double hw_us = hw_cyc * 0.01;   /* 100MHz */
            const char *verdict = "OK";
            if (hw_mkd != L || mku != L || mkc != L) verdict = "**MISMATCH**";
            printf(" %5d %6u %6u %6u %12u %10.2f %10.3f %8.2fx %9.3f %8.2fx  %u/%u/%u %s\n",
                   t, n, L, n - L, hw_cyc, hw_us, cu * 1000.0,
                   cu * 1000.0 / hw_us, cc * 1000.0, cc * 1000.0 / hw_us,
                   hw_mkd, mku, mkc, verdict);
            tot_hw += hw_us; tot_cu += cu * 1000.0; tot_cc += cc * 1000.0; tot_l += L;
        }
    }

    printf(" %s\n", "--------------------------------------------------------------------------------------------");
    printf(" totals: HW %.2f us | C-uncached %.3f us | C-cached %.3f us   (live objects %u)\n",
           tot_hw, tot_cu, tot_cc, tot_l);
    if (tot_hw > 0) {
        printf(" speedup HW vs C-uncached : %.1fx\n", tot_cu / tot_hw);
        printf(" speedup HW vs C-cached   : %.1fx\n", tot_cc / tot_hw);
        printf(" per object: HW %.1f cyc | C-uncached %.0f ns | C-cached %.0f ns\n",
               tot_hw * 100.0 / tot_l,
               (tot_cu * 1000.0) / tot_l,
               (tot_cc * 1000.0) / tot_l);
    }
    printf("======================================================================\n");

    munmap((void *)regs, 4096); munmap(gbase, GRAPH_SIZE); close(fd);
    return 0;
}
