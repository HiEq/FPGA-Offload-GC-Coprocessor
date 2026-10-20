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
# The binding targets the 32-bit ARM board build: fpga_gc_t contains two
# pointers and a size_t-sized field, so a 64-bit host would shift the offsets.
if ctypes.sizeof(ctypes.c_void_p) != 4:
    sys.stderr.write("ERROR: fogccc.py targets 32-bit ARM; this Python is %d-bit\n"
                     % (8 * ctypes.sizeof(ctypes.c_void_p)))
    sys.exit(1)


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

_lib.fpga_gc_status.restype = ctypes.c_uint32
_lib.fpga_gc_status.argtypes = [ctypes.POINTER(FpgaGcStruct)]

_lib.fpga_gc_read_mark.restype = ctypes.c_uint32
_lib.fpga_gc_read_mark.argtypes = [ctypes.POINTER(FpgaGcStruct), ctypes.c_uint32]


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
            'hw_us':     cycles_out.value * 0.01,   # 100 MHz -> 10 ns/cycle
            'elapsed_us': elapsed_us,               # wall clock (includes usleep)
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

    def status(self) -> int:
        """
        STATUS register (0x20): bit0 queue overflow, bit1 AXI read error,
        bit2 ref desync, bit3 bad object header. Cleared by the next start.
        """
        return _lib.fpga_gc_status(ctypes.byref(self._dev))

    def read_mark(self, obj_id: int) -> int:
        """Read one object's mark bit back through the bitmap probe (0x24/0x28)"""
        return _lib.fpga_gc_read_mark(ctypes.byref(self._dev), obj_id)

    def dump_marks(self, n: int = None) -> list:
        """Read the whole bitmap back, one probe round trip per object"""
        if n is None:
            n = self._dev.obj_count
        return [self.read_mark(i) for i in range(min(n, 4096))]


# ==================== 直接运行: 快速测试 ====================
if __name__ == '__main__':
    print("=" * 66)
    print("  FOGCCC Python Test (FPGA vs C vs bitmap readback)")
    print("=" * 66)

    try:
        with FOGCCC() as fpga:
            sizes = [10, 50, 100, 500, 1000, 2000, 4000]

            print(f"\n{'Objects':>8} {'FPGA':>7} {'SW':>7} {'HW(us)':>9} "
                  f"{'readback':>9} {'STATUS':>7} {'Match':>6}")
            print("-" * 66)

            ok = True
            for n in sizes:
                fpga.build_graph(n, avg_refs=3)
                roots = [0]
                fpga.set_roots(roots)

                sw_count = fpga.mark_sw(roots)
                r = fpga.mark()
                bits = sum(fpga.dump_marks(n))
                st = fpga.status()

                match = (r['marked'] == sw_count == bits) and st == 0
                ok = ok and match
                print(f"{n:>8} {r['marked']:>7} {sw_count:>7} "
                      f"{r['hw_us']:>9.1f} {bits:>9} {st:>7} "
                      f"{'OK' if match else 'FAIL':>6}")

            print()
            fpga.print_stats()
            print(f"\nOverall: {'PASS' if ok else 'FAIL'}")
            sys.exit(0 if ok else 1)

    except RuntimeError as e:
        print(f"\nError: {e}")
        sys.exit(1)
