// ============================================================
// fpga_gc.c — FOGCCC PS端驱动实现
// 平台: Xilinx Zynq-7000 XC7Z100
// ============================================================
#include "fpga_gc.h"
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// ============================================================
// 初始化
// ============================================================
int fpga_gc_init(fpga_gc_t *dev) {
    memset(dev, 0, sizeof(*dev));
    dev->fd = -1;

    // 打开/dev/mem (需要root权限)
    dev->fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (dev->fd < 0) {
        perror("ERROR: open /dev/mem (run as root: sudo)");
        return -1;
    }

    // 映射AXI-Lite寄存器
    dev->regs = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE,
                     MAP_SHARED, dev->fd, FPGA_BASE_ADDR);
    if (dev->regs == MAP_FAILED) {
        perror("ERROR: mmap AXI-Lite registers");
        close(dev->fd);
        dev->fd = -1;
        return -1;
    }

    // 映射DDR对象图区域
    dev->graph_vaddr = mmap(NULL, GRAPH_MAP_SIZE,
                            PROT_READ | PROT_WRITE,
                            MAP_SHARED, dev->fd, GRAPH_DDR_ADDR);
    if (dev->graph_vaddr == MAP_FAILED) {
        perror("ERROR: mmap graph DDR region");
        munmap((void *)dev->regs, MAP_SIZE);
        close(dev->fd);
        dev->fd = -1;
        return -1;
    }

    dev->graph_paddr = (uint32_t)GRAPH_DDR_ADDR;
    dev->obj_count   = 0;

    printf("[FOGCCC] Initialized:\n");
    printf("  AXI-Lite regs @ 0x%08X\n", (unsigned)FPGA_BASE_ADDR);
    printf("  Graph DDR     @ 0x%08X (1MB)\n", dev->graph_paddr);
    return 0;
}

// ============================================================
// 关闭
// ============================================================
void fpga_gc_close(fpga_gc_t *dev) {
    if (dev->graph_vaddr && dev->graph_vaddr != MAP_FAILED) {
        munmap(dev->graph_vaddr, GRAPH_MAP_SIZE);
        dev->graph_vaddr = NULL;
    }
    if (dev->regs && dev->regs != MAP_FAILED) {
        munmap((void *)dev->regs, MAP_SIZE);
        dev->regs = NULL;
    }
    if (dev->fd >= 0) {
        close(dev->fd);
        dev->fd = -1;
    }
}

// ============================================================
// 构建对象图到DDR
//
// 内存布局:
//   偏移 0x0000 ~ : 对象头区, 每16字节一个
//   偏移 0x1000 ~ : 引用数组区, 紧凑排列
//
// 对象k的头: @0x0000 + k*16
//   [id][ref_count][ref_array_phys_addr][reserved]
//
// 对象k的引用数组: @ref_array_phys_addr
//   [ref0][ref1]...[0xFFFFFFFF]
// ============================================================
int fpga_gc_build_graph(fpga_gc_t *dev, int n, int avg_refs) {
    if (n <= 0 || n > 4096) {
        printf("ERROR: invalid object count %d (1~4096, hardware limit)\n", n);
        return -1;
    }

    uint8_t *base       = (uint8_t *)dev->graph_vaddr;
    uint32_t graph_paddr = dev->graph_paddr;

    // 清零整个区域
    memset(base, 0, GRAPH_MAP_SIZE);

    uint32_t HDR_BASE  = 0x0000;   // 对象头起始偏移
    // 引用数组必须紧跟在"全部对象头"之后!
    // 原来硬编码 0x1000, 当 n > 256 时 (n*16 > 0x1000) 引用数组会覆盖对象头.
    uint32_t REF_BASE  = (HDR_BASE + (uint32_t)n * 16 + 0xFFFu) & ~0xFFFu;

    // 随机数种子 (固定, 保证可重复性)
    srand(42);

    // 第一遍: 分配引用数组空间
    uint32_t *ref_counts = (uint32_t *)malloc(n * sizeof(uint32_t));
    uint32_t *ref_offs   = (uint32_t *)malloc(n * sizeof(uint32_t));
    uint32_t  cur_off    = REF_BASE;

    for (int i = 0; i < n; i++) {
        // 每个对象都要有出边, 包括根对象.
        // 旧代码给对象0判了 rc=0, 只要根没有出边, BFS 第一步就停,
        // 1000 个对象的图也只标记 1 个 —— 性能对比完全失去意义.
        int rc = rand() % (avg_refs * 2 + 1);
        if (i == 0 && rc == 0) rc = avg_refs;   // 根至少有一条出边
        ref_counts[i] = rc;
        ref_offs[i]   = cur_off;
        cur_off += rc * 4 + 4;  // 引用 + 终止符
    }

    if (cur_off > GRAPH_MAP_SIZE) {
        printf("ERROR: graph too large (%u > %u bytes)\n",
               cur_off, GRAPH_MAP_SIZE);
        free(ref_counts);
        free(ref_offs);
        return -1;
    }

    // 第二遍: 写对象头
    for (int i = 0; i < n; i++) {
        uint32_t *hdr = (uint32_t *)(base + HDR_BASE + i * 16);
        hdr[0] = (uint32_t)i;                          // obj_id
        hdr[1] = ref_counts[i];                        // ref_count
        hdr[2] = graph_paddr + ref_offs[i];            // 引用数组物理地址
        hdr[3] = 0;                                    // reserved
    }

    // 第三遍: 写引用数组
    for (int i = 0; i < n; i++) {
        uint32_t *refs = (uint32_t *)(base + ref_offs[i]);
        for (uint32_t j = 0; j < ref_counts[i]; j++) {
            uint32_t target;
            if (n > 1) {
                target = (i + 1 + rand() % (n - 1)) % n;
                if (target == (uint32_t)i)
                    target = (target + 1) % n;
            } else {
                target = 0;
            }
            refs[j] = target;
        }
        refs[ref_counts[i]] = 0xFFFFFFFF;  // 终止符
    }

    free(ref_counts);
    free(ref_offs);

    dev->obj_count = n;
    printf("[FOGCCC] Graph: %d objects, %u bytes, avg_refs=%d\n",
           n, cur_off, avg_refs);
    return n;
}

// ============================================================
// 设置根集
// ============================================================
void fpga_gc_set_roots(fpga_gc_t *dev, uint32_t *roots, int n_roots) {
    // 寄存器地址已扩到 12 位: 0x40..0x43F 共 256 项
    if (n_roots > 256) {
        printf("WARNING: root count %d > 256, truncated\n", n_roots);
        n_roots = 256;
    }
    for (int i = 0; i < n_roots; i++) {
        dev->regs[(REG_ROOT_LIST + i * 4) / 4] = roots[i];
    }
    dev->regs[REG_ROOT_COUNT / 4] = (uint32_t)n_roots;
}

// ============================================================
// 启动FPGA标记, 等待完成
// ============================================================
uint32_t fpga_gc_mark(fpga_gc_t *dev, uint32_t *cycles_out) {
    // 写入对象图参数
    dev->regs[REG_OBJ_BASE  / 4] = dev->graph_paddr;
    dev->regs[REG_OBJ_COUNT / 4] = (uint32_t)dev->obj_count;

    // 清零队列 (位图由引擎在每轮 S_CLR_BM 自动清, CTRL[1] 已废弃无效)
    dev->regs[REG_CTRL / 4] = CTRL_CLEAR_Q;
    usleep(200);  // 等200μs确保清零完成

    // 启动
    dev->regs[REG_CTRL / 4] = CTRL_START;

    // 关键: START 是 AXI-Lite posted write, 紧接着的读可能先于写生效,
    // 从而读到【上一轮遗留的 DONE=1】并直接返回旧结果.
    // 先读一次 CTRL 把写刷下去 (同 master 的读写有序), 再轮询 DONE.
    (void)dev->regs[REG_CTRL / 4];
    usleep(1);

    // 轮询等待完成
    uint32_t timeout = 10000000;
    while (!(dev->regs[REG_CTRL / 4] & CTRL_DONE)) {
        if (--timeout == 0) {
            printf("ERROR: FPGA mark timeout after 10M polls!\n");
            if (cycles_out) *cycles_out = 0;
            return 0xFFFFFFFF;
        }
    }

    uint32_t marked = dev->regs[REG_MARKED / 4];
    uint32_t cycles = dev->regs[REG_CYCLES / 4];
    if (cycles_out) *cycles_out = cycles;
    return marked;
}

// ============================================================
// 软件BFS标记 (对照组)
// ============================================================
uint32_t fpga_gc_sw_mark(fpga_gc_t *dev, uint32_t *roots, int n_roots) {
    uint8_t *base        = (uint8_t *)dev->graph_vaddr;
    uint32_t graph_paddr = dev->graph_paddr;
    int      n           = dev->obj_count;

    uint8_t  *marked = (uint8_t *)calloc(n, 1);
    uint32_t *queue  = (uint32_t *)malloc(n * 4);
    uint32_t  head = 0, tail = 0, count = 0;

    // 入队根对象
    for (int i = 0; i < n_roots; i++) {
        uint32_t r = roots[i];
        if (r < (uint32_t)n && !marked[r]) {
            marked[r] = 1;
            queue[tail++] = r;
            count++;
        }
    }

    // BFS遍历
    while (head < tail) {
        uint32_t cur = queue[head++];

        // 读对象头
        uint32_t hdr_off    = cur * 16;
        uint32_t ref_count  = *(uint32_t *)(base + hdr_off + 4);
        uint32_t ref_phys   = *(uint32_t *)(base + hdr_off + 8);
        uint32_t ref_offset = ref_phys - graph_paddr;

        // 遍历引用
        for (uint32_t j = 0; j < ref_count; j++) {
            uint32_t target = *(uint32_t *)(base + ref_offset + j * 4);
            if (target == 0xFFFFFFFF) break;
            if (target < (uint32_t)n && !marked[target]) {
                marked[target] = 1;
                queue[tail++] = target;
                count++;
            }
        }
    }

    free(marked);
    free(queue);
    return count;
}

// ============================================================
// 读取单个对象的标记状态
// ============================================================
uint32_t fpga_gc_read_mark(fpga_gc_t *dev, uint32_t obj_id) {
    // 通过位图寄存器读取
    // 位图在BRAM中, 但当前寄存器接口未暴露位图读端口
    // 替代方案: 重新运行软件标记并对比
    // 或: 添加BM_ADDR/BM_DATA寄存器 (需要修改gc_regs.v)
    (void)dev; (void)obj_id;
    return 0;  // TODO: 需要扩展寄存器接口
}

// ============================================================
// 打印标记位图 (简化版: 通过软件标记对比)
// ============================================================
void fpga_gc_dump_marks(fpga_gc_t *dev, int n) {
    printf("Object reachability (from software reference):\n");
    uint32_t roots[] = {0};
    uint8_t *base = (uint8_t *)dev->graph_vaddr;
    // 使用软件标记作为参考输出
    // 实际FPGA位图需要ILA或扩展寄存器读取
    printf("  (Use ILA in Vivado to observe bitmap signals)\n");
    (void)dev; (void)n; (void)base; (void)roots;
}

// ============================================================
// 清除
// ============================================================
void fpga_gc_clear(fpga_gc_t *dev) {
    // 位图由引擎在每轮 S_CLR_BM 自动清, 这里只需要清队列
    dev->regs[REG_CTRL / 4] = CTRL_CLEAR_Q;
}

// ============================================================
// 打印硬件统计
// ============================================================
void fpga_gc_print_stats(fpga_gc_t *dev) {
    uint32_t cycles = dev->regs[REG_CYCLES / 4];
    uint32_t marked = dev->regs[REG_MARKED / 4];
    uint32_t q_head = dev->regs[REG_Q_HEAD / 4];
    uint32_t q_tail = dev->regs[REG_Q_TAIL / 4];
    double   time_us = cycles * 0.01;  // 100MHz → 10ns/周期

    printf("\n--- Hardware Statistics ---\n");
    printf("  Marked objects : %u\n", marked);
    printf("  HW cycles      : %u\n", cycles);
    printf("  HW time        : %.2f us (@100MHz)\n", time_us);
    printf("  Queue head/tail: %u / %u (depth=%u)\n",
           q_head, q_tail, q_tail - q_head);
    if (time_us > 0)
        printf("  Throughput     : %.2f M objects/sec\n",
               marked / time_us);
}
