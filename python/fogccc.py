"""
FOGCCC — Python ctypes 绑定
通过共享库调用C驱动, 与FPGA GC协处理器交互

使用前提:
  1. 先编译共享库:
     cd csrc && gcc -O2 -shared -fPIC -o libfogccc.so fpga_gc.c
  2. 把 libfogccc.so 放到 python/ 目录
  3. sudo python3 fogccc.py
"""
import ctypes
import time
import os
import sys

# ==================== 加载共享库 ====================
_HERE = os.path.dirname(os.path.abspath(__file__))
_SEARCH_PATHS = [
    os.path.join(_HERE, 'libfogccc.so'),
    os.path.join(_HERE, '..', 'csrc', 'libfogccc.so'),
    os.path.join(_HERE, '..', 'build', 'libfogccc.so'),
    './libfogccc.so',
]

_lib = None
for _p in _SEARCH_PATHS:
    if os.path.exists(_p):
        _lib = ctypes.CDLL(_p)
        break

if _lib is None:
    sys.stderr.write(
        "ERROR: libfogccc.so not found!\n"
        "Build it first:\n"
        "  cd ../csrc\n"
        "  gcc -O2 -shared -fPIC -o libfogccc.so fpga_gc.c\n"
    )
    sys.exit(1)


# ==================== C结构体定义 ====================
class FpgaGcStruct(ctypes.Structure):
    """对应 C 语言 fpga_gc_t"""
    _fields_ = [
        ('regs',         ctypes.c_void_p),
        ('fd',           ctypes.c_int),
        ('graph_vaddr',  ctypes.c_void_p),
        ('graph_paddr',  ctypes.c_uint32),
        ('obj_count',    ctypes.c_int),
    ]


# ==================== 注册C函数签名 ====================
_lib.fpga_gc_init.restype = ctypes.c_int
_lib.fpga_gc_init.argtypes = [ctypes.POINTER(FpgaGcStruct)]

_lib.fpga_gc_close.restype = None
_lib.fpga_gc_close.argtypes = [ctypes.POINTER(FpgaGcStruct)]

_lib.fpga_gc_build_graph.restype = ctypes.c_int
_lib.fpga_gc_build_graph.argtypes = [
    ctypes.POINTER(FpgaGcStruct),
    ctypes.c_int,    # n
    ctypes.c_int,    # avg_refs
]

_lib.fpga_gc_set_roots.restype = None
_lib.fpga_gc_set_roots.argtypes = [
    ctypes.POINTER(FpgaGcStruct),
    ctypes.POINTER(ctypes.c_uint32),
    ctypes.c_int,
]

_lib.fpga_gc_mark.restype = ctypes.c_uint32
_lib.fpga_gc_mark.argtypes = [
    ctypes.POINTER(FpgaGcStruct),
    ctypes.POINTER(ctypes.c_uint32),   # cycles_out
]

_lib.fpga_gc_sw_mark.restype = ctypes.c_uint32
_lib.fpga_gc_sw_mark.argtypes = [
    ctypes.POINTER(FpgaGcStruct),
    ctypes.POINTER(ctypes.c_uint32),
    ctypes.c_int,
]

_lib.fpga_gc_clear.restype = None
_lib.fpga_gc_clear.argtypes = [ctypes.POINTER(FpgaGcStruct)]

_lib.fpga_gc_print_stats.restype = None
_lib.fpga_gc_print_stats.argtypes = [ctypes.POINTER(FpgaGcStruct)]


# ==================== Python封装类 ====================
class FOGCCC:
    """
    FOGCCC FPGA GC协处理器 Python接口

    用法:
        with FOGCCC() as fpga:
            fpga.build_graph(1000, avg_refs=3)
            fpga.set_roots([0])
            result = fpga.mark()
            print(result)
    """

    def __init__(self):
        self._dev = FpgaGcStruct()
        ret = _lib.fpga_gc_init(ctypes.byref(self._dev))
        if ret != 0:
            raise RuntimeError(
                "FPGA GC init failed!\n"
                "  - Bitstream loaded?\n"
                "  - Running as root (sudo)?\n"
                "  - FPGA_BASE_ADDR correct?"
            )
        print("[FOGCCC] FPGA initialized successfully")

    def close(self):
        _lib.fpga_gc_close(ctypes.byref(self._dev))

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def build_graph(self, n: int, avg_refs: int = 3) -> int:
        """构建n个对象的测试图, 返回对象数"""
        result = _lib.fpga_gc_build_graph(
            ctypes.byref(self._dev), n, avg_refs
        )
        if result < 0:
            raise RuntimeError(f"Failed to build graph with {n} objects")
        return result

    def set_roots(self, roots: list):
        """设置根集, roots为对象ID列表"""
        arr = (ctypes.c_uint32 * len(roots))(*roots)
        _lib.fpga_gc_set_roots(
            ctypes.byref(self._dev), arr, len(roots)
        )

    def mark(self) -> dict:
        """
        执行FPGA标记
        返回: {'marked': int, 'cycles': int, 'elapsed_us': float}
        """
        cycles_out = ctypes.c_uint32(0)
        t0 = time.perf_counter_ns()
        marked = _lib.fpga_gc_mark(
            ctypes.byref(self._dev),
            ctypes.byref(cycles_out),
        )
        t1 = time.perf_counter_ns()
        elapsed_us = (t1 - t0) / 1000.0

        return {
            'marked':    marked,
            'cycles':    cycles_out.value,
            'elapsed_us': elapsed_us,
        }

    def mark_sw(self, roots: list) -> int:
        """软件BFS标记 (对照组)"""
        arr = (ctypes.c_uint32 * len(roots))(*roots)
        return _lib.fpga_gc_sw_mark(
            ctypes.byref(self._dev), arr, len(roots)
        )

    def clear(self):
        """清除位图和队列"""
        _lib.fpga_gc_clear(ctypes.byref(self._dev))

    def print_stats(self):
        """打印硬件统计信息"""
        _lib.fpga_gc_print_stats(ctypes.byref(self._dev))


# ==================== 直接运行: 快速测试 ====================
if __name__ == '__main__':
    print("=" * 55)
    print("  FOGCCC Python Test")
    print("=" * 55)

    try:
        with FOGCCC() as fpga:
            sizes = [10, 50, 100, 500, 1000, 2000, 4000]

            print(f"\n{'Objects':>8} {'FPGA':>8} {'SW':>8} "
                  f"{'FPGA(us)':>10} {'Match':>7} {'Speedup':>8}")
            print("-" * 55)

            for n in sizes:
                fpga.build_graph(n, avg_refs=3)
                roots = [0]
                fpga.set_roots(roots)

                # 软件标记
                t0 = time.perf_counter_ns()
                sw_count = fpga.mark_sw(roots)
                t1 = time.perf_counter_ns()
                sw_us = (t1 - t0) / 1000.0

                # FPGA标记
                result = fpga.mark()

                match = "OK" if result['marked'] == sw_count else "FAIL"
                speedup = (sw_us / result['elapsed_us']
                           if result['elapsed_us'] > 0 else 0)

                print(f"{n:>8} {result['marked']:>8} {sw_count:>8} "
                      f"{result['elapsed_us']:>10.1f} {match:>7} "
                      f"{speedup:>7.2f}x")

            print()
            fpga.print_stats()

    except RuntimeError as e:
        print(f"\nError: {e}")
        sys.exit(1)

    print("\nDone.")
