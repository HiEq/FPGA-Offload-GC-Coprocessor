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
// 运行: sudo ./test_main
// ============================================================
#include "fpga_gc.h"
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <time.h>
#include <string.h>

// 纳秒差转微秒
static double elapsed_us(struct timespec *t0, struct timespec *t1) {
    return (t1->tv_sec - t0->tv_sec) * 1e6 +
           (t1->tv_nsec - t0->tv_nsec) / 1e3;
}

// ============================================================
// Test 1: 正确性 + 性能 (FPGA vs C)
//
//   FPGA: CYCLES 寄存器 / 100 MHz, 不含驱动与睡眠开销
//   C   : fpga_gc_sw_mark() 的 C BFS (也是 marked 的独立 oracle)
//
// 只跟同阶段、同访问模式的 C 实现对比 (README「测量口径」)。
// ============================================================
#define GRAPH_AVG_REFS    3

static int test_correctness(fpga_gc_t *dev) {
    printf("\n");
    printf("=============================================================\n");
    printf("  Test 1: correctness + speed (FPGA vs C)\n");
    printf("=============================================================\n");
    printf("%-10s %-10s %-14s %-14s %-10s\n",
           "Objects", "marked", "FPGA us", "C us", "vs C");
    printf("---------- ---------- -------------- -------------- ----------\n");

    int sizes[] = {10, 50, 100, 500, 1000, 2000, 4000};
    int n_sizes = (int)(sizeof(sizes) / sizeof(sizes[0]));
    int all_pass = 1;
    int rows = 0;

    double best_hw_us = 0;
    int    best_n = 0, best_marked = 0;

    for (int s = 0; s < n_sizes; s++) {
        int n = sizes[s];

        // 构建图
        if (fpga_gc_build_graph(dev, n, GRAPH_AVG_REFS) < 0) {
            printf("  ERROR: fpga_gc_build_graph failed for n=%d\n", n);
            all_pass = 0;
            continue;
        }

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

        // ---- 结果 ----
        int match = (fpga_count == sw_count);
        char cbuf[16];
        if (hw_us > 0) snprintf(cbuf, sizeof cbuf, "%.1fx", sw_us / hw_us);
        else           snprintf(cbuf, sizeof cbuf, "n/a");

        printf("%-10d %-10u %-14.1f %-14.1f %-10s%s\n",
               n, fpga_count, hw_us, sw_us, cbuf,
               match ? "" : "  <<<< MISMATCH");
        rows++;

        // ---- STATUS must be clean: no overflow, no AXI error, no desync ----
        uint32_t st = fpga_gc_status(dev);
        if (st != 0) {
            printf("  STATUS=0x%X  (bit0=overflow bit1=axierr bit2=desync bit3=badhdr)\n", st);
            all_pass = 0;
        }

        // ---- queue tail must equal the mark count (one push per marked object;
        //      the 12-bit pointer wraps at 4096) ----
        {
            uint32_t qt = fpga_gc_q_tail(dev);
            if (qt != (fpga_count & 0xFFFU)) {
                printf("  q_tail=%u != marked=%u\n", qt, fpga_count);
                all_pass = 0;
            }
        }

        // ---- bitmap readback (0x24/0x28): compare the SET, not just the count ----
        // The probe is checked object by object against the software BFS.
        {
            uint8_t *sw_bits = (uint8_t *)calloc((size_t)n, 1);
            int bm_bad = 0;
            if (!sw_bits) {
                printf("  ERROR: calloc failed for the bitmap compare (n=%d)\n", n);
                all_pass = 0;
            } else {
                fpga_gc_sw_mark_bits(dev, roots, 1, sw_bits);
                for (int o = 0; o < n; o++) {
                    uint32_t hb = fpga_gc_read_mark(dev, (uint32_t)o);
                    if (hb != (uint32_t)sw_bits[o]) {
                        if (bm_bad < 3)
                            printf("  bitmap mismatch obj %d: hw=%u sw=%u\n",
                                   o, (unsigned)hb, (unsigned)sw_bits[o]);
                        bm_bad++;
                    }
                }
                free(sw_bits);
            }
            if (bm_bad) {
                printf("  bitmap readback: %d object(s) differ from the SW BFS\n", bm_bad);
                all_pass = 0;
            }
        }
        if (!match) all_pass = 0;
        if (n == sizes[n_sizes - 1]) {
            best_n = n; best_marked = (int)fpga_count;
            best_hw_us = hw_us;
        }
    }

    if (rows != n_sizes) {
        printf("  ERROR: %d of %d sizes produced no result row\n", n_sizes - rows, n_sizes);
        all_pass = 0;
    }
    printf("  Result: %s\n", all_pass ? "ALL PASS" : "SOME FAILED");

    if (best_n > 0) {
        printf("\n  >>> %d objects marked in %.1f us (%.1f ns/obj)\n",
               best_marked, best_hw_us, best_hw_us * 1000.0 / best_marked);
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
    uint32_t expected = fpga_gc_sw_mark(dev, roots, 1);   /* independent oracle */

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

        if (count != expected) {
            printf("  Run %d: marked %u != expected %u\n", i, count, expected);
            pass = 0;
        }
        if (fpga_gc_status(dev) != 0) {
            printf("  Run %d: STATUS=0x%X\n", i, fpga_gc_status(dev));
            pass = 0;
        }
        if (fpga_gc_q_tail(dev) != (count & 0xFFFU)) {
            printf("  Run %d: q_tail %u != marked %u\n", i, fpga_gc_q_tail(dev), count);
            pass = 0;
        }

        // The first run also compares the full bitmap against the SW BFS.
        if (i == 0) {
            uint8_t *bits = (uint8_t *)calloc((size_t)n, 1);
            if (!bits) {
                printf("  ERROR: calloc failed for the bitmap compare\n");
                pass = 0;
            } else {
                fpga_gc_sw_mark_bits(dev, roots, 1, bits);
                for (int o = 0; o < n; o++) {
                    if (fpga_gc_read_mark(dev, (uint32_t)o) != (uint32_t)bits[o]) {
                        printf("  Run 0: bitmap mismatch at obj %d\n", o);
                        pass = 0;
                        break;
                    }
                }
                free(bits);
            }
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

    printf("  Expected: %u  Marked: %u (consistent across 100 runs)\n", expected, ref_count);
    printf("  Cycles: min=%u max=%u jitter=%u\n",
           min_cycles, max_cycles, max_cycles - min_cycles);
    printf("  Result: %s\n", pass ? "PASS" : "FAIL");
    return pass;
}

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
    (void)argv;

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
    int pass1 = test_correctness(&dev);
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
