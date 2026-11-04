// verify_c_build.c - FOGCCC graph-build route check.
//
// Two C variants are timed on the same 4000-object graph:
//   direct : fpga_gc_build_graph() writes every header/ref into the uncached
//            /dev/mem graph window (the existing C builder).
//   cached : build the identical bytes in a cached malloc buffer, then one
//            memcpy() into the graph window.
//
// Both variants are then checked against the software BFS and the hardware
// marker (count, STATUS and the full bitmap).
#include "fpga_gc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdint.h>

#define N_OBJECTS 4000
#define AVG_REFS  3
#define REPS      5

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

// Same generator as fpga_gc_build_graph(), but into a caller-supplied buffer.
// Returns the number of bytes actually used (headers + ref arrays).
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

static int verify(fpga_gc_t *dev, int n, const char *tag)
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
    printf("  verify[%s] marked=%u sw=%u status=0x%X cycles=%u bitmap_bad=%d\n",
           tag, hw, sw, st, cycles, bm_bad);
    return (hw != sw) || (st != 0) || (bm_bad != 0);
}

int main(void)
{
    fpga_gc_t dev;
    double direct[REPS], cached[REPS], copy[REPS];
    uint32_t used = 0;
    uint32_t *stage = NULL;
    int i, rc = 0, bad;

    printf("FOGCCC C graph-build route check\n");
    if (fpga_gc_init(&dev) < 0) return 1;

    for (i = 0; i < REPS; i++) {
        double t0 = now_ms();
        if (fpga_gc_build_graph(&dev, N_OBJECTS, AVG_REFS) < 0) return 1;
        direct[i] = now_ms() - t0;
    }
    printf("C_BUILD mode=direct n=%d avg_refs=%d reps=%d median_ms=%.3f min_ms=%.3f\n",
           N_OBJECTS, AVG_REFS, REPS, median(direct, REPS),
           direct[0] < direct[REPS - 1] ? direct[0] : direct[REPS - 1]);
    bad = check_layout(&dev, N_OBJECTS, GRAPH_MAP_SIZE);
    printf("C_BUILD layout_direct_bad=%d\n", bad);
    rc |= bad;
    rc |= verify(&dev, N_OBJECTS, "direct");

    stage = (uint32_t *)malloc(GRAPH_MAP_SIZE);
    if (!stage) return 1;
    for (i = 0; i < REPS; i++) {
        double t0 = now_ms();
        used = build_cached((uint8_t *)stage, dev.graph_paddr, N_OBJECTS, AVG_REFS);
        cached[i] = now_ms() - t0;
        t0 = now_ms();
        memcpy(dev.graph_vaddr, stage, used);
        copy[i] = now_ms() - t0;
        cached[i] += copy[i];
    }
    printf("C_BUILD mode=cached n=%d avg_refs=%d reps=%d used=%u median_total_ms=%.3f total_min_ms=%.3f copy_median_ms=%.3f\n",
           N_OBJECTS, AVG_REFS, REPS, used, median(cached, REPS),
           cached[0] < cached[REPS - 1] ? cached[0] : cached[REPS - 1],
           median(copy, REPS));
    bad = check_layout(&dev, N_OBJECTS, used);
    printf("C_BUILD layout_cached_bad=%d\n", bad);
    rc |= bad;
    dev.obj_count = N_OBJECTS;
    rc |= verify(&dev, N_OBJECTS, "cached");

    printf("C_BUILD_SUMMARY direct_median_ms=%.3f cached_median_ms=%.3f speedup=%.2fx python_ref_ms=102.2 speedup_vs_python=%.1fx\n",
           median(direct, REPS), median(cached, REPS),
           median(direct, REPS) / median(cached, REPS),
           102.2 / median(cached, REPS));
    printf("C_BUILD_RESULT %s\n", rc == 0 && bad == 0 ? "OK" : "FAIL");

    free(stage);
    fpga_gc_close(&dev);
    return rc == 0 && bad == 0 ? 0 : 1;
}
