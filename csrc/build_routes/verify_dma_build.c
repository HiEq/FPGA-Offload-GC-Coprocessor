// verify_dma_build.c - FOGCCC DMA graph-build route check.
//
// Builds the 4000-object side-table in a cached malloc buffer, copies it into
// the 256 KiB coherent staging buffer exported by fogccc_dma.ko, then moves it
// to the FPGA graph DDR window (0x1E000000) with the Zynq PS DMA controller
// (PL330).  The result is checked against the software BFS and the hardware
// marker exactly like verify_c_build.
#include "fpga_gc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

#define N_OBJECTS 4000
#define AVG_REFS  3
#define REPS      5
#define DMA_DEV   "/dev/fogccc_dma"

struct fogccc_dma_info {
    uint32_t size;
    uint32_t src_phys;
    uint32_t dst_phys;
};

struct fogccc_dma_copy {
    uint32_t dst_phys;
    uint32_t len;
};

#define FOGCCC_DMA_IOC_MAGIC 'F'
#define FOGCCC_DMA_IOC_INFO _IOR(FOGCCC_DMA_IOC_MAGIC, 0, struct fogccc_dma_info)
#define FOGCCC_DMA_IOC_COPY _IOW(FOGCCC_DMA_IOC_MAGIC, 1, struct fogccc_dma_copy)

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

static int cmp_double(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static double median(double *v, int n)
{
    qsort(v, n, sizeof(*v), cmp_double);
    return v[n / 2];
}

static uint32_t build_cached(uint8_t *base, uint32_t graph_paddr,
                             int n, int avg_refs)
{
    uint32_t HDR_BASE = 0x0000;
    uint32_t REF_BASE = (HDR_BASE + (uint32_t)n * 16 + 0xFFFu) & ~0xFFFu;
    uint32_t *ref_counts = (uint32_t *)malloc((size_t)n * sizeof(uint32_t));
    uint32_t *ref_offs   = (uint32_t *)malloc((size_t)n * sizeof(uint32_t));
    uint32_t cur_off = REF_BASE;
    int i;

    if (!ref_counts || !ref_offs) {
        free(ref_counts);
        free(ref_offs);
        return 0;
    }
    memset(base, 0, GRAPH_MAP_SIZE);
    srand(42);
    for (i = 0; i < n; i++) {
        int rc = rand() % (avg_refs * 2 + 1);
        if (i == 0 && rc == 0) rc = avg_refs;
        ref_counts[i] = (uint32_t)rc;
        ref_offs[i] = cur_off;
        cur_off += (uint32_t)rc * 4 + 4;
    }
    if (cur_off > GRAPH_MAP_SIZE) {
        free(ref_counts);
        free(ref_offs);
        return 0;
    }
    for (i = 0; i < n; i++) {
        uint32_t *hdr = (uint32_t *)(base + HDR_BASE + (uint32_t)i * 16);
        hdr[0] = (uint32_t)i;
        hdr[1] = ref_counts[i];
        hdr[2] = graph_paddr + ref_offs[i];
        hdr[3] = 0;
    }
    for (i = 0; i < n; i++) {
        uint32_t *refs = (uint32_t *)(base + ref_offs[i]);
        uint32_t j;
        for (j = 0; j < ref_counts[i]; j++) {
            uint32_t target;
            if (n > 1) {
                target = ((uint32_t)i + 1 + (uint32_t)rand() % ((uint32_t)n - 1)) % (uint32_t)n;
                if (target == (uint32_t)i) target = (target + 1) % (uint32_t)n;
            } else {
                target = 0;
            }
            refs[j] = target;
        }
        refs[ref_counts[i]] = 0xFFFFFFFFu;
    }
    free(ref_counts);
    free(ref_offs);
    return cur_off;
}

static int check_layout(fpga_gc_t *dev, int n, uint32_t used)
{
    const uint8_t *base = (const uint8_t *)dev->graph_vaddr;
    uint32_t paddr = dev->graph_paddr;
    int i, bad = 0;

    if (used > GRAPH_MAP_SIZE) {
        printf("  layout: used=%u > %u\n", used, (unsigned)GRAPH_MAP_SIZE);
        return 1;
    }
    for (i = 0; i < n; i++) {
        const uint32_t *hdr = (const uint32_t *)(base + (uint32_t)i * 16);
        uint32_t rc = hdr[1], addr = hdr[2], j;
        uint32_t off = addr - paddr;
        if (hdr[0] != (uint32_t)i || rc > 4096 || (addr & 3) ||
            addr < paddr || off >= used || off + (rc + 1) * 4 > used) {
            if (bad < 3)
                printf("  layout bad header obj=%d id=%u rc=%u addr=0x%08x off=%u\n",
                       i, hdr[0], rc, addr, off);
            bad++;
            continue;
        }
        {
            const uint32_t *refs = (const uint32_t *)(base + off);
            for (j = 0; j < rc; j++) {
                if (refs[j] >= (uint32_t)n) {
                    if (bad < 3) printf("  layout bad ref obj=%d j=%u val=%u\n", i, j, refs[j]);
                    bad++;
                }
            }
            if (refs[rc] != 0xFFFFFFFFu) {
                if (bad < 3) printf("  layout missing terminator obj=%d rc=%u\n", i, rc);
                bad++;
            }
        }
    }
    return bad;
}

static int verify(fpga_gc_t *dev, int n)
{
    uint32_t roots[1] = {0};
    uint32_t cycles = 0;
    uint32_t hw, sw, st;
    uint8_t *bits = (uint8_t *)calloc((size_t)n, 1);
    int i, bm_bad = 0;

    if (!bits) return 1;
    fpga_gc_set_roots(dev, roots, 1);
    sw = fpga_gc_sw_mark(dev, roots, 1);
    hw = fpga_gc_mark(dev, &cycles);
    st = fpga_gc_status(dev);
    fpga_gc_sw_mark_bits(dev, roots, 1, bits);
    for (i = 0; i < n; i++) {
        uint32_t hb = fpga_gc_read_mark(dev, (uint32_t)i);
        if (hb != (uint32_t)bits[i]) {
            if (bm_bad < 3)
                printf("  bitmap mismatch obj=%d hw=%u sw=%u\n", i, hb, bits[i]);
            bm_bad++;
        }
    }
    free(bits);
    printf("  verify[dma] marked=%u sw=%u status=0x%X cycles=%u bitmap_bad=%d\n",
           hw, sw, st, cycles, bm_bad);
    return (hw != sw) || (st != 0) || (bm_bad != 0);
}

int main(void)
{
    fpga_gc_t dev;
    struct fogccc_dma_info info;
    struct fogccc_dma_copy cp;
    uint8_t *stage = NULL;
    uint32_t *buf = NULL;
    double build[REPS], stage_ms[REPS], dma[REPS], total[REPS];
    uint32_t used = 0;
    int fd = -1, i, rc = 0, bad;

    printf("FOGCCC DMA graph-build route check\n");
    if (fpga_gc_init(&dev) < 0) return 1;

    fd = open(DMA_DEV, O_RDWR);
    if (fd < 0) {
        perror("open " DMA_DEV " (insmod fogccc_dma.ko first)");
        fpga_gc_close(&dev);
        return 2;
    }
    if (ioctl(fd, FOGCCC_DMA_IOC_INFO, &info) < 0) {
        perror("ioctl INFO");
        close(fd); fpga_gc_close(&dev); return 2;
    }
    if (info.size < 128 * 1024) {
        printf("ERROR: DMA staging %u too small for a 4000-object graph\n", info.size);
        close(fd); fpga_gc_close(&dev); return 2;
    }
    stage = (uint8_t *)mmap(NULL, info.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (stage == MAP_FAILED) {
        perror("mmap dma stage");
        close(fd); fpga_gc_close(&dev); return 2;
    }
    buf = (uint32_t *)malloc(GRAPH_MAP_SIZE);
    if (!buf) return 1;

    printf("DMA_INFO size=%u src_phys=0x%08x dst=0x%08x\n",
           info.size, info.src_phys, info.dst_phys);

    for (i = 0; i < REPS; i++) {
        double t0 = now_ms();
        used = build_cached((uint8_t *)buf, dev.graph_paddr, N_OBJECTS, AVG_REFS);
        if (used > info.size) {
            printf("ERROR: graph uses %u > staging %u\n", used, info.size);
            rc = 1;
            break;
        }

        double t1 = now_ms();
        memcpy(stage, buf, used);

        double t2 = now_ms();
        cp.dst_phys = dev.graph_paddr;
        cp.len = used;
        if (ioctl(fd, FOGCCC_DMA_IOC_COPY, &cp) < 0) {
            perror("ioctl COPY");
            rc = 1;
            break;
        }
        double t3 = now_ms();

        build[i] = t1 - t0;
        stage_ms[i] = t2 - t1;
        dma[i] = t3 - t2;
        total[i] = t3 - t0;
        dev.obj_count = N_OBJECTS;
    }
    if (rc == 0) {
        printf("DMA_BUILD n=%d avg_refs=%d reps=%d used=%u build_median_ms=%.3f stage_median_ms=%.3f dma_median_ms=%.3f total_median_ms=%.3f\n",
               N_OBJECTS, AVG_REFS, REPS, used, median(build, REPS),
               median(stage_ms, REPS), median(dma, REPS), median(total, REPS));
        bad = check_layout(&dev, N_OBJECTS, used);
        printf("DMA_BUILD layout_bad=%d\n", bad);
        rc |= bad;
        rc |= verify(&dev, N_OBJECTS);
        printf("DMA_BUILD_SUMMARY total_median_ms=%.3f python_ref_ms=102.2 speedup_vs_python=%.1fx\n",
               median(total, REPS), 102.2 / median(total, REPS));
        printf("DMA_BUILD_RESULT %s\n", rc == 0 ? "OK" : "FAIL");
    }

    munmap(stage, info.size);
    close(fd);
    free(buf);
    fpga_gc_close(&dev);
    return rc;
}
