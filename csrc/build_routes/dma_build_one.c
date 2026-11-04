// dma_build_one.c - build one FOGCCC side-table with cached C + PL330 DMA.
//
// usage: dma_build_one <objects> [avg_refs]
// prints: DMA_BUILD_ONE n=... avg_refs=... used=... build_ms=... stage_ms=... dma_ms=... total_ms=...
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

#define DMA_DEV "/dev/fogccc_dma"
#define REPS 5

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

int main(int argc, char **argv)
{
    int n = argc > 1 ? atoi(argv[1]) : 4000;
    int avg_refs = argc > 2 ? atoi(argv[2]) : 3;
    struct fogccc_dma_info info;
    struct fogccc_dma_copy cp;
    uint8_t *buf, *stage;
    uint32_t used = 0;
    double build_t[REPS], stage_t[REPS], dma_t[REPS], total_t[REPS];
    int fd, i;

    if (n <= 0 || n > 4096) { fprintf(stderr, "bad n\n"); return 2; }
    if (avg_refs <= 0 || avg_refs > 1024) {
        fprintf(stderr, "bad avg_refs\n");
        return 2;
    }

    buf = (uint8_t *)malloc(GRAPH_MAP_SIZE);
    if (!buf) return 2;
    fd = open(DMA_DEV, O_RDWR);
    if (fd < 0) { perror("open " DMA_DEV); free(buf); return 2; }
    if (ioctl(fd, FOGCCC_DMA_IOC_INFO, &info) < 0) {
        perror("ioctl INFO"); close(fd); free(buf); return 2;
    }
    stage = (uint8_t *)mmap(NULL, info.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (stage == MAP_FAILED) {
        perror("mmap"); close(fd); free(buf); return 2;
    }

    for (i = 0; i < REPS; i++) {
        double t0 = now_ms();
        used = build_cached(buf, GRAPH_DDR_ADDR, n, avg_refs);
        double t1 = now_ms();
        if (used == 0) {
            fprintf(stderr, "graph too large or out of memory\n");
            munmap(stage, info.size); close(fd); free(buf); return 2;
        }
        if (used > info.size) {
            fprintf(stderr, "graph uses %u > staging %u\n", used, info.size);
            munmap(stage, info.size); close(fd); free(buf); return 2;
        }
        memcpy(stage, buf, used);
        double t2 = now_ms();
        cp.dst_phys = GRAPH_DDR_ADDR;
        cp.len = used;
        if (ioctl(fd, FOGCCC_DMA_IOC_COPY, &cp) < 0) {
            perror("ioctl COPY");
            munmap(stage, info.size); close(fd); free(buf); return 2;
        }
        double t3 = now_ms();
        build_t[i] = t1 - t0;
        stage_t[i] = t2 - t1;
        dma_t[i] = t3 - t2;
        total_t[i] = t3 - t0;
    }

    double total_min = total_t[0];
    for (i = 1; i < REPS; i++)
        if (total_t[i] < total_min) total_min = total_t[i];

    printf("DMA_BUILD_ONE n=%d avg_refs=%d used=%u reps=%d build_ms=%.3f stage_ms=%.3f dma_ms=%.3f total_ms=%.3f total_min_ms=%.3f\n",
           n, avg_refs, used, REPS, median(build_t, REPS), median(stage_t, REPS),
           median(dma_t, REPS), median(total_t, REPS), total_min);

    munmap(stage, info.size);
    close(fd);
    free(buf);
    return 0;
}
