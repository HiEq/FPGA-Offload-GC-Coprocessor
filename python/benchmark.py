"""
FOGCCC — CPython 纯软件GC基准测试
用于与FPGA标记延迟对比

运行: python3 benchmark.py [iterations]
"""
import gc
import time
import random
import sys


class GCTestObj:
    """测试用对象 (使用__slots__减少内存开销)"""
    __slots__ = ['idx', 'refs']

    def __init__(self, idx):
        self.idx = idx
        self.refs = []


def build_object_graph(n: int, avg_refs: int = 3):
    """构建n个对象的引用图"""
    random.seed(42)
    objs = [GCTestObj(i) for i in range(n)]
    for obj in objs:
        if obj.idx == 0:
            continue
        k = random.randint(0, avg_refs * 2)
        targets = random.sample(objs, min(k, len(objs)))
        obj.refs = targets
    return objs


def benchmark_full_gc(iterations: int = 50):
    """基准: CPython gc.collect() 完整GC延迟"""
    gc.disable()
    sizes = [10, 50, 100, 500, 1000, 2000, 4000]
    results = {}

    print("=" * 55)
    print("  CPython gc.collect() Full GC Baseline")
    print("=" * 55)
    print(f"{'Objects':>8} {'Avg(us)':>12} {'Min(us)':>12} {'Max(us)':>12}")
    print("-" * 55)

    for n in sizes:
        objs = build_object_graph(n)     # keep a reference: without it the graph is
                                         # garbage before the timed collect

        times = []
        for _ in range(iterations):
            gc.collect()
            t0 = time.perf_counter_ns()
            gc.collect()
            t1 = time.perf_counter_ns()
            times.append((t1 - t0) / 1000.0)

        avg = sum(times) / len(times)
        results[n] = avg
        print(f"{n:>8} {avg:>12.1f} {min(times):>12.1f} "
              f"{max(times):>12.1f}")

    gc.enable()
    return results


def benchmark_mark_phase(iterations: int = 50):
    """基准: 标记阶段 (第二轮collect, 无新垃圾)"""
    gc.disable()
    sizes = [100, 500, 1000, 2000, 4000]
    results = {}

    print(f"\n{'=' * 55}")
    print("  CPython GC Mark Phase (warm)")
    print("=" * 55)
    print(f"{'Objects':>8} {'Avg(us)':>12}")
    print("-" * 30)

    for n in sizes:
        objs = build_object_graph(n)     # keep a reference: without it the graph is
                                         # garbage before the timed collect

        times = []
        for _ in range(iterations):
            gc.collect()  # 第一轮: 清除
            t0 = time.perf_counter_ns()
            gc.collect()  # 第二轮: 主要是标记
            t1 = time.perf_counter_ns()
            times.append((t1 - t0) / 1000.0)

        avg = sum(times) / len(times)
        results[n] = avg
        print(f"{n:>8} {avg:>12.1f}")

    gc.enable()
    return results


def compare_with_fpga():
    """显示如何与FPGA结果对比"""
    print(f"\n{'=' * 55}")
    print("  How to Compare with FPGA")
    print("=" * 55)
    print("""
  1. Run this benchmark on the board:
       python3 benchmark.py

  2. Run FPGA test on the board:
       sudo ./bin/test_main

  3. Compare:
       ┌──────────┬──────────────┬──────────────┐
       │ Objects  │ Python (us)  │ FPGA (us)    │
       ├──────────┼──────────────┼──────────────┤
       │ 100      │ ~xx.x        │ ~xx.x        │
       │ 1000     │ ~xx.x        │ ~xx.x        │
       │ 4000     │ ~xx.x        │ ~xx.x        │
       └──────────┴──────────────┴──────────────┘

  4. Note: Python gc.collect() includes mark+clear+sweep
     FPGA only does mark. For fair comparison, use the
     'Mark Phase' numbers above.
""")


if __name__ == '__main__':
    iterations = 50
    if len(sys.argv) > 1:
        iterations = int(sys.argv[1])

    print(f"Python {sys.version}")
    print(f"Iterations: {iterations}\n")

    benchmark_full_gc(iterations)
    benchmark_mark_phase(iterations)
    compare_with_fpga()
