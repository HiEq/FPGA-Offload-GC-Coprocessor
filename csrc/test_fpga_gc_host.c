// ============================================================
// test_fpga_gc_host.c — x86 host tests for the PS driver.
//
// No /dev/mem and no board: the register file and graph are heap buffers.
// The expected BFS result is a hand-written graph, not produced by fpga_gc.c.
//
// Build/run (CI):
//   gcc -O2 -Wall -Wextra -Werror -pthread -I csrc \
//       csrc/fpga_gc.c csrc/test_fpga_gc_host.c -o /tmp/test_fpga_gc_host
//   /tmp/test_fpga_gc_host
// ============================================================
#define _DEFAULT_SOURCE
#include "fpga_gc.h"

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failures;

#define CHECK(cond, ...)                                                     \
    do {                                                                     \
        if (!(cond)) {                                                       \
            failures++;                                                      \
            printf("FAIL %s:%d: ", __FILE__, __LINE__);                      \
            printf(__VA_ARGS__);                                             \
            printf("\n");                                                    \
        }                                                                    \
    } while (0)

static void attach(fpga_gc_t *dev, uint32_t *regs, uint8_t *graph, int n) {
    memset(dev, 0, sizeof(*dev));
    dev->regs = regs;
    dev->graph_vaddr = graph;
    dev->graph_paddr = 0x1E000000u;
    dev->obj_count = n;
    dev->fd = -1;
}

static void put_header(uint8_t *graph, int i, uint32_t ref_count, uint32_t ref_phys) {
    uint32_t *h = (uint32_t *)(graph + (size_t)i * 16u);
    h[0] = (uint32_t)i;
    h[1] = ref_count;
    h[2] = ref_phys;
    h[3] = 0;
}

static void put_refs(uint8_t *graph, uint32_t ref_off, const uint32_t *refs, uint32_t n) {
    uint32_t *dst = (uint32_t *)(graph + ref_off);
    memcpy(dst, refs, (size_t)n * sizeof(uint32_t));
    dst[n] = 0xFFFFFFFFu;
}

static void test_valid_bfs(void) {
    uint8_t *graph = (uint8_t *)calloc(1, GRAPH_MAP_SIZE);
    uint32_t *regs = (uint32_t *)calloc(MAP_SIZE / 4u, sizeof(uint32_t));
    uint8_t bits[6];
    uint32_t roots[2];
    fpga_gc_t dev;
    const uint32_t r0[] = {1, 2};
    const uint32_t r1[] = {3};
    const uint32_t r2[] = {3};
    const uint32_t r3[] = {0};

    attach(&dev, regs, graph, 6);
    put_header(graph, 0, 2, dev.graph_paddr + 0x1000u);
    put_header(graph, 1, 1, dev.graph_paddr + 0x1010u);
    put_header(graph, 2, 1, dev.graph_paddr + 0x1020u);
    put_header(graph, 3, 1, dev.graph_paddr + 0x1030u);
    put_header(graph, 4, 0, dev.graph_paddr + 0x1040u);
    put_header(graph, 5, 0, dev.graph_paddr + 0x1050u);
    put_refs(graph, 0x1000u, r0, 2);
    put_refs(graph, 0x1010u, r1, 1);
    put_refs(graph, 0x1020u, r2, 1);
    put_refs(graph, 0x1030u, r3, 1);

    roots[0] = 0;
    memset(bits, 0, sizeof(bits));
    CHECK(fpga_gc_sw_mark_bits(&dev, roots, 1, bits) == 4,
          "root 0: expected 4 marked");
    CHECK(bits[0] == 1 && bits[1] == 1 && bits[2] == 1 && bits[3] == 1,
          "root 0: expected objects 0..3 marked");
    CHECK(bits[4] == 0 && bits[5] == 0, "root 0: islands must stay unmarked");

    roots[0] = 5;
    memset(bits, 0, sizeof(bits));
    CHECK(fpga_gc_sw_mark_bits(&dev, roots, 1, bits) == 1,
          "root 5: expected 1 marked");
    CHECK(bits[5] == 1 && bits[0] == 0, "root 5: expected only object 5");

    roots[0] = 0;
    roots[1] = 0;
    memset(bits, 0, sizeof(bits));
    CHECK(fpga_gc_sw_mark_bits(&dev, roots, 2, bits) == 4,
          "duplicate roots: expected 4 marked");

    free(graph);
    free(regs);
    printf("  valid_bfs: done\n");
}

static void test_bad_headers(void) {
    uint8_t *graph = (uint8_t *)calloc(1, GRAPH_MAP_SIZE);
    uint32_t *regs = (uint32_t *)calloc(MAP_SIZE / 4u, sizeof(uint32_t));
    uint8_t bits[4];
    uint32_t roots[1] = {0};
    fpga_gc_t dev;

    attach(&dev, regs, graph, 1);

    // ref_count > 4096: the hardware rejects it via err_hdr; the software
    // reference must not walk the array.
    put_header(graph, 0, 4097, dev.graph_paddr + 0x1000u);
    CHECK(fpga_gc_sw_mark_bits(&dev, roots, 1, bits) == 0xFFFFFFFFu,
          "ref_count=4097 must be rejected");

    // ref_addr below the graph: unsigned underflow would read outside the
    // buffer.  Must be rejected.
    put_header(graph, 0, 1, 0u);
    CHECK(fpga_gc_sw_mark_bits(&dev, roots, 1, bits) == 0xFFFFFFFFu,
          "ref_addr below the graph must be rejected");

    // ref array crosses the 1 MiB end.
    put_header(graph, 0, 4, dev.graph_paddr + GRAPH_MAP_SIZE - 4u);
    CHECK(fpga_gc_sw_mark_bits(&dev, roots, 1, bits) == 0xFFFFFFFFu,
          "ref array crossing the graph end must be rejected");

    free(graph);
    free(regs);
    printf("  bad_headers: done\n");
}

static void test_set_roots_negative(void) {
    uint32_t *regs = (uint32_t *)calloc(MAP_SIZE / 4u, sizeof(uint32_t));
    uint8_t *graph = (uint8_t *)calloc(1, GRAPH_MAP_SIZE);
    uint32_t roots[1] = {0};
    fpga_gc_t dev;

    attach(&dev, regs, graph, 4);
    fpga_gc_set_roots(&dev, roots, -1);
    CHECK(regs[REG_ROOT_COUNT / 4] == 0,
          "negative root count must clamp to 0, got 0x%08x",
          regs[REG_ROOT_COUNT / 4]);

    free(regs);
    free(graph);
    printf("  set_roots_negative: done\n");
}

typedef struct {
    volatile uint32_t *regs;
} mark_mock_t;

static void *mark_mock_thread(void *arg) {
    mark_mock_t *m = (mark_mock_t *)arg;
    for (;;) {
        if (m->regs[REG_CTRL / 4] & CTRL_START) {
            m->regs[REG_MARKED / 4] = 7;
            m->regs[REG_CYCLES / 4] = 123;
            m->regs[REG_CTRL / 4] |= CTRL_DONE;
            return NULL;
        }
        usleep(1);
    }
}

static void test_mark_registers(void) {
    uint32_t *regs = (uint32_t *)calloc(MAP_SIZE / 4u, sizeof(uint32_t));
    uint8_t *graph = (uint8_t *)calloc(1, GRAPH_MAP_SIZE);
    fpga_gc_t dev;
    pthread_t tid;
    mark_mock_t mock;
    uint32_t cycles = 0;
    uint32_t marked;
    int created;

    attach(&dev, regs, graph, 6);
    mock.regs = regs;
    created = pthread_create(&tid, NULL, mark_mock_thread, &mock);
    CHECK(created == 0, "pthread_create failed");
    if (created != 0) {
        free(regs);
        free(graph);
        return;
    }
    marked = fpga_gc_mark(&dev, &cycles);
    CHECK(pthread_join(tid, NULL) == 0, "pthread_join failed");

    CHECK(marked == 7, "fpga_gc_mark must return MARKED, got %u", marked);
    CHECK(cycles == 123, "fpga_gc_mark must return CYCLES, got %u", cycles);
    CHECK(regs[REG_OBJ_BASE / 4] == dev.graph_paddr,
          "OBJ_BASE write: got 0x%08x", regs[REG_OBJ_BASE / 4]);
    CHECK(regs[REG_OBJ_COUNT / 4] == 6,
          "OBJ_COUNT write: got %u", regs[REG_OBJ_COUNT / 4]);
    CHECK((regs[REG_CTRL / 4] & CTRL_START) != 0,
          "CTRL START was not written");

    // Timeout path: no DONE.  Pre-set IDLE so wait_idle returns immediately.
    memset(regs, 0, MAP_SIZE);
    regs[REG_STATUS / 4] = STATUS_IDLE;
    attach(&dev, regs, graph, 6);
    marked = fpga_gc_mark(&dev, &cycles);
    CHECK(marked == 0xFFFFFFFFu, "timeout must return 0xFFFFFFFF, got %u", marked);
    CHECK(regs[REG_CTRL / 4] == CTRL_ABORT,
          "timeout must write CTRL_ABORT, got 0x%08x", regs[REG_CTRL / 4]);

    free(regs);
    free(graph);
    printf("  mark_registers: done\n");
}

static void test_read_mark(void) {
    uint32_t *regs = (uint32_t *)calloc(MAP_SIZE / 4u, sizeof(uint32_t));
    uint8_t *graph = (uint8_t *)calloc(1, GRAPH_MAP_SIZE);
    fpga_gc_t dev;

    attach(&dev, regs, graph, 8);

    // Not idle: the probe is not valid.
    CHECK(fpga_gc_read_mark(&dev, 5) == 0xFFFFFFFFu,
          "probe while busy must return 0xFFFFFFFF");

    regs[REG_STATUS / 4] = STATUS_IDLE;
    regs[REG_BM_DATA / 4] = 1u << 5;
    CHECK(fpga_gc_read_mark(&dev, 5) == 1u, "bit 5 must read 1");
    CHECK(fpga_gc_read_mark(&dev, 6) == 0u, "bit 6 must read 0");
    CHECK(fpga_gc_read_mark(&dev, 4096) == 0u, "obj_id 4096 is out of range");

    free(regs);
    free(graph);
    printf("  read_mark: done\n");
}

static void test_build_graph(void) {
    uint8_t *graph = (uint8_t *)calloc(1, GRAPH_MAP_SIZE);
    uint32_t *regs = (uint32_t *)calloc(MAP_SIZE / 4u, sizeof(uint32_t));
    fpga_gc_t dev;
    int n = 16;
    int i;

    attach(&dev, regs, graph, 0);
    CHECK(fpga_gc_build_graph(&dev, n, 2) == n, "build_graph must return n");
    CHECK(dev.obj_count == n, "obj_count must be n");

    for (i = 0; i < n; i++) {
        uint32_t *h = (uint32_t *)(graph + (size_t)i * 16u);
        uint32_t ref_off = h[2] - dev.graph_paddr;
        CHECK(h[0] == (uint32_t)i, "header %d id=%u", i, h[0]);
        CHECK(h[1] <= 4u, "header %d ref_count=%u above avg_refs*2", i, h[1]);
        CHECK(h[2] >= dev.graph_paddr &&
              h[2] < dev.graph_paddr + (uint32_t)GRAPH_MAP_SIZE,
              "header %d ref_addr=0x%08x outside the graph", i, h[2]);
        CHECK(h[3] == 0, "header %d reserved != 0", i);
        CHECK(ref_off + h[1] * 4u + 4u <= (uint32_t)GRAPH_MAP_SIZE,
              "header %d ref array outside the graph", i);
        CHECK(((uint32_t *)(graph + ref_off))[h[1]] == 0xFFFFFFFFu,
              "header %d ref array has no terminator", i);
    }

    free(graph);
    free(regs);
    printf("  build_graph: done\n");
}

int main(void) {
    printf("[HOST] fpga_gc host tests\n");
    test_valid_bfs();
    test_bad_headers();
    test_set_roots_negative();
    test_mark_registers();
    test_read_mark();
    test_build_graph();

    if (failures == 0) {
        printf("[HOST] ==================== PASS ====================\n");
        return 0;
    }
    printf("[HOST] FAIL: %d check(s)\n", failures);
    return 1;
}
