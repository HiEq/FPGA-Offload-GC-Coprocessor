// ============================================================
// test_main.c — FOGCCC 测试主程序
//
// 测试内容:
//   Test 1: 正确性 + 性能 (多种规模)
//   Test 2: 循环图 (含环)
//   Test 3: 重复执行一致性 (100次)
//
// 编译: 用 PetaLinux SDK 交叉编译 (板上没有 gcc)
//       $CC -O2 -o test_main fpga_gc.c test_main.c
// 运行: sudo ./test_main  [py_bfs.py 路径]
// ============================================================
#include "fpga_gc.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <string.h>

// 纳秒差转微秒
static double elapsed_us(struct timespec *t0, struct timespec *t1) {
    return (t1->tv_sec - t0->tv_sec) * 1e6 +
           (t1->tv_nsec - t0->tv_nsec) / 1e3;
}

// ============================================================
// Test 1: 正确性 + 性能 (FPGA vs C vs CPython)
//
//   FPGA   : CYCLES 寄存器 / 100 MHz, 不含驱动与睡眠开销
//   C      : fpga_gc_sw_mark() 的 C BFS
//   CPython: py_bfs.py, 独立进程遍历同一块 DDR
// ============================================================
#define PY_BFS_DEFAULT "/run/media/USERDATA-mmcblk0p2/tests/py_bfs.py"

// 让 CPython 标记同一张图, 返回毫秒 (失败返回 -1)
static double cpython_mark_ms(const char *py, int n, uint32_t paddr,
                              uint32_t root, uint32_t *count_out) {
    char cmd[512];
    if (count_out) *count_out = 0;
    snprintf(cmd, sizeof cmd, "python3 '%s' %d 0x%08X %u 2>/dev/null",
             py, n, (unsigned)paddr, (unsigned)root);
    FILE *p = popen(cmd, "r");
    if (!p) return -1.0;
    double ms = -1.0;
    unsigned pc = 0;
    if (fscanf(p, "%lf %u", &ms, &pc) != 2) ms = -1.0;
    pclose(p);
    if (count_out) *count_out = pc;
    return ms;
}

static int test_correctness(fpga_gc_t *dev, const char *py_path) {
    printf("\n");
    printf("=============================================================\n");
    printf("  Test 1: correctness + speed (FPGA vs C vs CPython)\n");
    printf("=============================================================\n");
    printf("%-8s %-8s %-11s %-11s %-13s %-8s %-9s\n",
           "Objects", "marked", "FPGA us", "C us", "py_bfs ms",
           "vs C", "vs CPython");
    printf("-------- -------- ----------- ----------- ------------- "
           "-------- ---------\n");

    int sizes[] = {10, 50, 100, 500, 1000, 2000, 4000};
    int n_sizes = (int)(sizeof(sizes) / sizeof(sizes[0]));
    int all_pass = 1;

    double best_hw_us = 0, best_py_ms = 0, best_py_x = 0;
    int    best_n = 0, best_marked = 0;

    for (int s = 0; s < n_sizes; s++) {
        int n = sizes[s];

        // 构建图
        if (fpga_gc_build_graph(dev, n, 3) < 0) continue;

        // 设置根集
        uint32_t roots[] = {0};
        fpga_gc_set_roots(dev, roots, 1);

        // ---- C 基准 (同一张图, 同一套 BFS) ----
        struct timespec t0, t1;
        clock_gettime(CLOCK_MONOTONIC, &t0);
        uint32_t sw_count = fpga_gc_sw_mark(dev, roots, 1);
        clock_gettime(CLOCK_MONOTONIC, &t1);
        double sw_us = elapsed_us(&t0, &t1);

        // ---- FPGA (只认 CYCLES 寄存器, 不掺驱动开销) ----
        uint32_t cycles = 0;
        uint32_t fpga_count = fpga_gc_mark(dev, &cycles);
        double hw_us = cycles * 0.01;          // 100 MHz -> 10 ns/cycle

        // ---- CPython 基准 (独立进程, 独立实现) ----
        uint32_t py_count = 0;
        double py_ms = cpython_mark_ms(py_path, n, dev->graph_paddr,
                                       roots[0], &py_count);

        // ---- 结果 ----
        // py_ms < 0 means the baseline could not run; one that DID run must agree.
        int py_ok = (py_ms >= 0.0);
        int match = (fpga_count == sw_count) && (!py_ok || py_count == fpga_count);
        char cbuf[16], pbuf[16], nbuf[16];
        if (hw_us > 0) snprintf(cbuf, sizeof cbuf, "%.1fx", sw_us / hw_us);
        else           snprintf(cbuf, sizeof cbuf, "n/a");
        if (py_ms > 0 && hw_us > 0) {
            snprintf(pbuf, sizeof pbuf, "%.0fx", py_ms * 1000.0 / hw_us);
            snprintf(nbuf, sizeof nbuf, "%.3f", py_ms);
        } else {
            snprintf(pbuf, sizeof pbuf, "n/a");
            snprintf(nbuf, sizeof nbuf, "n/a");
        }

        printf("%-8d %-8u %-11.1f %-11.1f %-13s %-8s %-9s%s\n",
               n, fpga_count, hw_us, sw_us, nbuf, cbuf, pbuf,
               match ? "" : "  <<<< MISMATCH");

        // ---- STATUS must be clean: no overflow, no AXI error, no desync ----
        uint32_t st = fpga_gc_status(dev);
        if (st != 0) {
            printf("  STATUS=0x%X  (bit0=overflow bit1=axierr bit2=desync bit3=badhdr)\n", st);
            all_pass = 0;
        }

        // ---- bitmap readback (0x24/0x28) must agree with MARKED ----
        uint32_t bits = 0;
        for (int o = 0; o < n; o++)
            bits += fpga_gc_read_mark(dev, (uint32_t)o);
        if (bits != fpga_count) {
            printf("  bitmap readback=%u != MARKED=%u (probe broken)\n", bits, fpga_count);
            all_pass = 0;
        }
        if (!match) all_pass = 0;
        if (n == sizes[n_sizes - 1]) {
            best_n = n; best_marked = (int)fpga_count;
            best_hw_us = hw_us; best_py_ms = py_ms;
            best_py_x = (py_ms > 0 && hw_us > 0) ? py_ms * 1000.0 / hw_us : 0;
        }
    }

    printf("  Result: %s\n", all_pass ? "ALL PASS" : "SOME FAILED");

    if (best_py_x > 0) {
        printf("\n  >>> %d objects marked in %.1f us (%.1f ns/obj)\n",
               best_marked, best_hw_us, best_hw_us * 1000.0 / best_marked);
        printf("  >>> CPython needs %.2f ms for the same graph\n", best_py_ms);
        printf("  >>> FPGA is %.0fx FASTER than CPython\n", best_py_x);
    } else if (best_n > 0) {
        printf("\n  (CPython baseline unavailable: %s not found?)\n", py_path);
    }

    return all_pass;
}

// ============================================================
// Test 2: 循环图 (含环)
//
// 图结构:
//   0 → 1 → 2 → 0   (环: 0,1,2互相可达)
//   3 → 1            (对象3可达环)
//   4 → (无引用)      (对象4孤立, 不可达)
//
// 根集 = {0, 3}
// 预期标记 = {0,1,2,3} = 4个 (对象4不可达)
// ============================================================
static int test_cycle(fpga_gc_t *dev) {
    printf("\n");
    printf("=============================================\n");
    printf("  Test 2: Cycle Graph\n");
    printf("=============================================\n");

    int n = 5;
    if (fpga_gc_build_graph(dev, n, 2) < 0) return 0;

    // 手动覆盖图结构
    uint8_t *base = (uint8_t *)dev->graph_vaddr;
    uint32_t paddr = dev->graph_paddr;
    uint32_t REF_BASE = 0x1000;

    // 对象0: 引用{1}
    *(uint32_t *)(base + 0*16 + 4) = 1;          // ref_count
    *(uint32_t *)(base + 0*16 + 8) = paddr + REF_BASE; // ref_addr
    *(uint32_t *)(base + REF_BASE + 0) = 1;
    *(uint32_t *)(base + REF_BASE + 4) = 0xFFFFFFFF;

    // 对象1: 引用{2}
    *(uint32_t *)(base + 1*16 + 4) = 1;
    *(uint32_t *)(base + 1*16 + 8) = paddr + REF_BASE + 8;
    *(uint32_t *)(base + REF_BASE + 8)  = 2;
    *(uint32_t *)(base + REF_BASE + 12) = 0xFFFFFFFF;

    // 对象2: 引用{0} (形成环!)
    *(uint32_t *)(base + 2*16 + 4) = 1;
    *(uint32_t *)(base + 2*16 + 8) = paddr + REF_BASE + 16;
    *(uint32_t *)(base + REF_BASE + 16) = 0;
    *(uint32_t *)(base + REF_BASE + 20) = 0xFFFFFFFF;

    // 对象3: 引用{1}
    *(uint32_t *)(base + 3*16 + 4) = 1;
    *(uint32_t *)(base + 3*16 + 8) = paddr + REF_BASE + 24;
    *(uint32_t *)(base + REF_BASE + 24) = 1;
    *(uint32_t *)(base + REF_BASE + 28) = 0xFFFFFFFF;

    // 对象4: 无引用 (孤立)
    *(uint32_t *)(base + 4*16 + 4) = 0;
    *(uint32_t *)(base + 4*16 + 8) = paddr + REF_BASE + 32;
    *(uint32_t *)(base + REF_BASE + 32) = 0xFFFFFFFF;

    // 根集 = {0, 3}
    uint32_t roots[] = {0, 3};
    fpga_gc_set_roots(dev, roots, 2);

    // 软件标记
    uint32_t sw_count = fpga_gc_sw_mark(dev, roots, 2);

    // FPGA标记
    uint32_t cycles = 0;
    uint32_t fpga_count = fpga_gc_mark(dev, &cycles);

    int expected = 4;  // {0,1,2,3} 可达, {4} 不可达
    int pass = (fpga_count == (uint32_t)expected) &&
               (sw_count == (uint32_t)expected);

    printf("  Graph: 0->1->2->0 (cycle), 3->1, 4 (isolated)\n");
    printf("  Roots: {0, 3}\n");
    printf("  Expected: %d  SW: %u  FPGA: %u  => %s\n",
           expected, sw_count, fpga_count,
           pass ? "PASS" : "FAIL");
    return pass;
}

// ============================================================
// Test 3: 重复执行一致性
// ============================================================
static int test_repeat(fpga_gc_t *dev) {
    printf("\n");
    printf("=============================================\n");
    printf("  Test 3: Repeat Consistency (100 runs)\n");
    printf("=============================================\n");

    int n = 1000;
    if (fpga_gc_build_graph(dev, n, 3) < 0) return 0;

    uint32_t roots[] = {0};
    fpga_gc_set_roots(dev, roots, 1);

    uint32_t ref_count = 0;
    uint32_t min_cycles = 0xFFFFFFFF, max_cycles = 0;
    int pass = 1;

    for (int i = 0; i < 100; i++) {
        uint32_t cycles = 0;
        uint32_t count = fpga_gc_mark(dev, &cycles);

        // 0xFFFFFFFF is the documented timeout sentinel (fpga_gc.h). Without
        // this check, 100 timeouts are "100 identical runs" and the test passes.
        if (count == 0xFFFFFFFF) {
            printf("  Run %d: FPGA TIMEOUT (mark returned 0xFFFFFFFF)\n", i);
            pass = 0;
            continue;
        }

        if (i == 0) {
            ref_count = count;
        } else if (count != ref_count) {
            printf("  Run %d: count mismatch %u != %u\n",
                   i, count, ref_count);
            pass = 0;
        }

        if (cycles < min_cycles) min_cycles = cycles;
        if (cycles > max_cycles) max_cycles = cycles;
    }

    printf("  Marked count: %u (consistent across 100 runs)\n", ref_count);
    printf("  Cycles: min=%u max=%u jitter=%u\n",
           min_cycles, max_cycles, max_cycles - min_cycles);
    printf("  Result: %s\n", pass ? "PASS" : "FAIL");
    return pass;
}

// ============================================================
// 主函数
// ============================================================
// ============================================================
// Test 4: duplicate roots must be counted once
//   roots {0,0,0} and {0} must both mark the same set. The engine
//   checks the bitmap before pushing a root, so the second and third
//   copy are skipped (no double push, no double count).
// ============================================================
static int test_dup_roots(fpga_gc_t *dev) {
    printf("\n");
    printf("=============================================\n");
    printf("  Test 4: duplicate roots\n");
    printf("=============================================\n");

    if (fpga_gc_build_graph(dev, 200, 3) < 0) return 0;

    uint32_t one[1] = {0};
    uint32_t dup[3] = {0, 0, 0};

    fpga_gc_set_roots(dev, one, 1);
    uint32_t c1 = fpga_gc_mark(dev, NULL);
    uint32_t st1 = fpga_gc_status(dev);

    fpga_gc_set_roots(dev, dup, 3);
    uint32_t c3 = fpga_gc_mark(dev, NULL);
    uint32_t st3 = fpga_gc_status(dev);

    int pass = (c1 == c3) && (c1 > 1) && (st1 == 0) && (st3 == 0)
               && (c1 != 0xFFFFFFFF) && (c3 != 0xFFFFFFFF);   /* timeout sentinel */
    printf("  roots={0}      -> marked=%u  STATUS=0x%X\n", c1, st1);
    printf("  roots={0,0,0}  -> marked=%u  STATUS=0x%X\n", c3, st3);
    printf("  %s (duplicate roots must not double count, expect %u == %u)\n",
           pass ? "PASS" : "FAIL", c1, c3);
    return pass;
}
int main(int argc, char **argv) {
    printf("+--------------------------------------------+\n");
    printf("|  FOGCCC GC Coprocessor Test Suite          |\n");
    printf("|  Platform: Xilinx Zynq-7000 XC7Z100        |\n");
    printf("+--------------------------------------------+\n");
    (void)argc;
    // 可选参数: CPython 基准脚本路径
    const char *py_path = (argc > 1) ? argv[1] : PY_BFS_DEFAULT;

    // 初始化FPGA
    fpga_gc_t dev;
    if (fpga_gc_init(&dev) < 0) {
        printf("\nFPGA initialization FAILED!\n");
        printf("Checklist:\n");
        printf("  1. Bitstream loaded?  cat /sys/class/fpga_manager/fpga0/state\n");
        printf("  2. Running as root?   sudo ./test_main\n");
        printf("  3. Address correct?   FPGA_BASE_ADDR in fpga_gc.h\n");
        return 1;
    }

    // 运行测试
    int pass1 = test_correctness(&dev, py_path);
    int pass2 = test_cycle(&dev);
    int pass3 = test_repeat(&dev);
    int pass4 = test_dup_roots(&dev);

    // 打印硬件统计
    fpga_gc_print_stats(&dev);

    // 汇总
    int all_pass = pass1 && pass2 && pass3 && pass4;
    printf("\n");
    printf("=============================================\n");
    printf("  SUMMARY\n");
    printf("=============================================\n");
    printf("  Test 1 (Correctness) : %s\n", pass1 ? "PASS" : "FAIL");
    printf("  Test 2 (Cycle)       : %s\n", pass2 ? "PASS" : "FAIL");
    printf("  Test 3 (Repeat)      : %s\n", pass3 ? "PASS" : "FAIL");
    printf("  Test 4 (Dup roots)   : %s\n", pass4 ? "PASS" : "FAIL");
    printf("  -------------------------------------------\n");
    printf("  Overall: %s\n", all_pass ? "*** ALL PASS ***" : "*** FAILED ***");
    printf("=============================================\n");

    fpga_gc_close(&dev);
    return all_pass ? 0 : 1;
}
