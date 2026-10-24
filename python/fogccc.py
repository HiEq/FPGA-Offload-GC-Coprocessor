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
        # Phase 3A: appended in the same order as fpga_gc_t in csrc/fpga_gc.h
        ('dirty_tag',       ctypes.c_uint32),
        ('dirty_tag_valid', ctypes.c_uint32),
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

_lib.fpga_gc_sw_mark_cached.restype = ctypes.c_uint32
_lib.fpga_gc_sw_mark_cached.argtypes = [
    ctypes.POINTER(FpgaGcStruct),
    ctypes.POINTER(ctypes.c_uint32),
    ctypes.c_int,
]

_lib.fpga_gc_sw_mark_us.restype = ctypes.c_uint32
_lib.fpga_gc_sw_mark_us.argtypes = [
    ctypes.POINTER(FpgaGcStruct),
    ctypes.POINTER(ctypes.c_uint32),
    ctypes.c_int,
    ctypes.c_int,
    ctypes.POINTER(ctypes.c_double),
]

_lib.fpga_gc_clear.restype = None
_lib.fpga_gc_clear.argtypes = [ctypes.POINTER(FpgaGcStruct)]

_lib.fpga_gc_print_stats.restype = None
_lib.fpga_gc_print_stats.argtypes = [ctypes.POINTER(FpgaGcStruct)]

_lib.fpga_gc_status.restype = ctypes.c_uint32
_lib.fpga_gc_status.argtypes = [ctypes.POINTER(FpgaGcStruct)]

_lib.fpga_gc_read_mark.restype = ctypes.c_uint32
_lib.fpga_gc_read_mark.argtypes = [ctypes.POINTER(FpgaGcStruct), ctypes.c_uint32]

# Phase 3A: 屏障脏集 + 增量 epoch
_lib.fpga_gc_dirty_push.restype = None
_lib.fpga_gc_dirty_push.argtypes = [ctypes.POINTER(FpgaGcStruct), ctypes.c_uint32]

_lib.fpga_gc_dirty_flush.restype = None
_lib.fpga_gc_dirty_flush.argtypes = [ctypes.POINTER(FpgaGcStruct)]

_lib.fpga_gc_dirty_status.restype = ctypes.c_uint32
_lib.fpga_gc_dirty_status.argtypes = [ctypes.POINTER(FpgaGcStruct)]

_lib.fpga_gc_dirty_drained.restype = ctypes.c_uint32
_lib.fpga_gc_dirty_drained.argtypes = [ctypes.POINTER(FpgaGcStruct)]

_lib.fpga_gc_dirty_pushed.restype = ctypes.c_uint32
_lib.fpga_gc_dirty_pushed.argtypes = [ctypes.POINTER(FpgaGcStruct)]

_lib.fpga_gc_dirty_popped.restype = ctypes.c_uint32
_lib.fpga_gc_dirty_popped.argtypes = [ctypes.POINTER(FpgaGcStruct)]

_lib.fpga_gc_mark_incremental.restype = ctypes.c_uint32
_lib.fpga_gc_mark_incremental.argtypes = [ctypes.POINTER(FpgaGcStruct), ctypes.POINTER(ctypes.c_uint32)]

# ---- complete ctypes declarations (tests/test_repo_contract.py enforces these)
_P = ctypes.POINTER(FpgaGcStruct)
_lib.fpga_gc_init.restype = ctypes.c_int
_lib.fpga_gc_init.argtypes = [_P]
_lib.fpga_gc_close.restype = None
_lib.fpga_gc_close.argtypes = [_P]
_lib.fpga_gc_build_graph.restype = ctypes.c_int
_lib.fpga_gc_build_graph.argtypes = [_P, ctypes.c_int, ctypes.c_int]
_lib.fpga_gc_set_roots.restype = None
_lib.fpga_gc_set_roots.argtypes = [_P, ctypes.POINTER(ctypes.c_uint32), ctypes.c_int]
_lib.fpga_gc_mark.restype = ctypes.c_uint32
_lib.fpga_gc_mark.argtypes = [_P, ctypes.POINTER(ctypes.c_uint32)]
_lib.fpga_gc_mark_incremental.restype = ctypes.c_uint32
_lib.fpga_gc_mark_incremental.argtypes = [_P, ctypes.POINTER(ctypes.c_uint32)]
_lib.fpga_gc_sw_mark.restype = ctypes.c_uint32
_lib.fpga_gc_sw_mark.argtypes = [_P, ctypes.POINTER(ctypes.c_uint32), ctypes.c_int]
_lib.fpga_gc_clear.restype = None
_lib.fpga_gc_clear.argtypes = [_P]
_lib.fpga_gc_status.restype = ctypes.c_uint32
_lib.fpga_gc_status.argtypes = [_P]
_lib.fpga_gc_read_mark.restype = ctypes.c_uint32
_lib.fpga_gc_read_mark.argtypes = [_P, ctypes.c_uint32]
_lib.fpga_gc_print_stats.restype = None
_lib.fpga_gc_print_stats.argtypes = [_P]
_lib.fpga_gc_dirty_push.restype = None
_lib.fpga_gc_dirty_push.argtypes = [_P, ctypes.c_uint32]
_lib.fpga_gc_dirty_push_acked.restype = ctypes.c_int
_lib.fpga_gc_dirty_push_acked.argtypes = [_P, ctypes.c_uint32, ctypes.c_int]
_lib.fpga_gc_dirty_flush.restype = None
_lib.fpga_gc_dirty_flush.argtypes = [_P]
_lib.fpga_gc_dirty_status.restype = ctypes.c_uint32
_lib.fpga_gc_dirty_status.argtypes = [_P]
_lib.fpga_gc_dirty_drained.restype = ctypes.c_uint32
_lib.fpga_gc_dirty_drained.argtypes = [_P]
_lib.fpga_gc_dirty_pushed.restype = ctypes.c_uint32
_lib.fpga_gc_dirty_pushed.argtypes = [_P]
_lib.fpga_gc_dirty_popped.restype = ctypes.c_uint32
_lib.fpga_gc_dirty_popped.argtypes = [_P]



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

    def mark_sw_us(self, roots: list, cached: bool = False):
        """(count, us) with the BFS timed inside C; cached uses a heap copy."""
        arr = (ctypes.c_uint32 * len(roots))(*roots)
        us = ctypes.c_double(0.0)
        count = _lib.fpga_gc_sw_mark_us(
            ctypes.byref(self._dev), arr, len(roots), 1 if cached else 0,
            ctypes.byref(us)
        )
        return count, us.value

    def mark_sw_cached(self, roots: list) -> int:
        """C BFS on a heap-resident copy of the same graph (cache-resident bound)"""
        arr = (ctypes.c_uint32 * len(roots))(*roots)
        return _lib.fpga_gc_sw_mark_cached(
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

    # ---- Phase 3A: 屏障脏集 + 增量 epoch ------------------------------------
    def dirty_push(self, obj_id: int):
        """推一条屏障记录。屏障契约：先把指针存储对 PL 可见（回读/屏障）再调本函数。
        内部维护变化的 tag（本板写路径会重投递 store）。"""
        _lib.fpga_gc_dirty_push(ctypes.byref(self._dev), ctypes.c_uint32(obj_id))

    def dirty_flush(self):
        """Arm a dirty-FIFO flush.

        The write only ARMS: it takes effect at the next full-mark start
        (``mark()``, BM_KEEP=0) and is discarded by an incremental start.
        """
        _lib.fpga_gc_dirty_flush(ctypes.byref(self._dev))

    def dirty_push_acked(self, obj_id: int, retries: int = 4) -> bool:
        """Push a barrier record and confirm the FIFO accepted this id.

        Reads DIRTY_STAT[31:20] (last accepted id) and [19:16] (tag); retries with
        a fresh tag on a mismatch.  A sticky overflow returns False.  When this
        returns False the caller must fall back to a full mark.  The 16-bit
        signature detects a mismatch but is not a proof.
        """
        return bool(_lib.fpga_gc_dirty_push_acked(
            ctypes.byref(self._dev), ctypes.c_uint32(obj_id), ctypes.c_int(retries)))

    def dirty_status(self) -> dict:
        """DIRTY_STAT(0x444)：occ / overflow(粘滞) / pending / 最后接受的 tag 与 id"""
        st = _lib.fpga_gc_dirty_status(ctypes.byref(self._dev))
        return {'raw': st, 'occ': st & 0x1FF, 'overflow': (st >> 9) & 1,
                'pending': (st >> 10) & 1, 'tag': (st >> 16) & 0xF,
                'id': (st >> 20) & 0xFFF}

    def barrier_verify(self, ids) -> bool:
        """True when every listed id is marked after the epoch.

        Pass one target per dirtied container.  All marked means no missed mark was
        observed; anything unmarked must trigger a full mark.  Necessary, not
        sufficient: a target already marked before the epoch hides whether its
        container was re-scanned.  One bitmap probe per id (0x24/0x28).
        """
        return all(self.read_mark(int(i)) for i in ids)

    def dirty_push_verified(self, obj_id: int, retries: int = 4, poll: int = 8) -> bool:
        """Push a barrier record and confirm the command reached the FIFO.

        Reads DIRTY_STAT[19:16] back and retries with a fresh tag on a mismatch;
        a sticky overflow returns False.  Confirms the command, not the id:
        use ``dirty_push_acked()`` for an id-level check.
        """
        for _ in range(retries + 1):
            _lib.fpga_gc_dirty_push(ctypes.byref(self._dev), ctypes.c_uint32(obj_id))
            want = self._dev.dirty_tag & 0xF
            for _ in range(poll):
                st = self.dirty_status()
                if st['overflow']:
                    return False
                if st['tag'] == want:
                    return True
        return False

    def dirty_counts(self) -> dict:
        """drained(本 epoch) / pushed(上次 flush 以来接受) / popped(上次 flush 以来消费)"""
        return {'drained': _lib.fpga_gc_dirty_drained(ctypes.byref(self._dev)),
                'pushed':  _lib.fpga_gc_dirty_pushed(ctypes.byref(self._dev)),
                'popped':  _lib.fpga_gc_dirty_popped(ctypes.byref(self._dev))}

    def mark_incremental(self) -> dict:
        """增量 epoch：保留位图(CTRL[4]=BM_KEEP) 且**不** flush；根集由调用者设置
        （增量步通常 roots=0，remark 亦然）。返回与 mark() 同形状的 dict。"""
        cycles_out = ctypes.c_uint32(0)
        t0 = time.perf_counter_ns()
        marked = _lib.fpga_gc_mark_incremental(
            ctypes.byref(self._dev), ctypes.byref(cycles_out))
        t1 = time.perf_counter_ns()
        return {'marked': marked, 'cycles': cycles_out.value,
                'hw_us': cycles_out.value * 0.01, 'elapsed_us': (t1 - t0) / 1000.0}

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
