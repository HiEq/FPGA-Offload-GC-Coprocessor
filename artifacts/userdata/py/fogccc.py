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

    # ---- Phase 3A: 屏障脏集 + 增量 epoch ------------------------------------
    def dirty_push(self, obj_id: int):
        """推一条屏障记录。屏障契约：先把指针存储对 PL 可见（回读/屏障）再调本函数。
        内部维护变化的 tag（本板写路径会重投递 store）。"""
        _lib.fpga_gc_dirty_push(ctypes.byref(self._dev), ctypes.c_uint32(obj_id))

    def dirty_flush(self):
        """Arm a dirty-FIFO flush.

        Since the 2026-10-23 arm-and-consume contract the CTRL write only ARMS the
        flush: it takes effect at the next full-mark start (``mark()``, i.e. with
        BM_KEEP=0) and is DISCARDED by an incremental start.  Call ``dirty_flush()``
        before a full mark, exactly like the C driver does - a bare flush on its own
        no longer clears anything immediately.
        """
        _lib.fpga_gc_dirty_flush(ctypes.byref(self._dev))

    def dirty_push_acked(self, obj_id: int, retries: int = 4) -> bool:
        """Push a barrier record and confirm the FIFO accepted THIS id (AGENTS #20).

        Reads DIRTY_STAT[31:20] (last accepted id) together with [19:16] (last
        accepted tag) back after each attempt: only when both match the push just
        issued did the id land.  A mismatch retries with a fresh tag; a sticky
        overflow bit returns False.  Unlike ``dirty_push_verified()`` this is an
        id-level check -- a foreign W beat shows up as a different id -- so the
        caller can retry, and when the budget runs out it must fall back to a full
        mark.  Costs one register read per attempt.

        The signature is 16 bits (4-bit tag + 12-bit id): it detects a mismatch, but a
        foreign store that happens to carry exactly that 16-bit value is
        indistinguishable from ours, so this is a strong check, not a proof.
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
        """Check that a barrier's effect is visible: no id it was meant to re-scan is unmarked.

        AGENTS #20 makes an incremental epoch best-effort (the platform can mis-pair a
        W beat, so a DIRTY_PUSH record can be lost).  The mutator knows the new edges
        it wrote, so after the epoch it can check one target per dirtied container:
        all marked -> **no missed mark was observed** (treat the epoch as exact);
        anything unmarked -> fall back to ``mark()`` from the true roots.

        This is a NECESSARY, not a sufficient check: a target that was already marked
        before the epoch hides whether its container was re-scanned at all, so only
        pass targets this epoch newly reaches, or confirm with a full oracle/count.
        One bitmap probe per id (0x24/0x28).
        """
        return all(self.read_mark(int(i)) for i in ids)

    def dirty_push_verified(self, obj_id: int, retries: int = 4, poll: int = 8) -> bool:
        """Push a barrier record and confirm the command reached the FIFO (AGENTS #20).

        The plain ``dirty_push()`` is fire-and-forget: on this board the write path
        redelivers stores and can pair a W beat with another store's address, which
        both forges and loses records.  This variant reads DIRTY_STAT[19:16] back
        and returns True when the tag it just wrote is the one the FIFO reports
        (retrying with a fresh tag otherwise; a repeated id is only a forced
        re-scan).  A set sticky overflow bit returns False: fall back to a full
        mark.  Costs one register read per push.

        LIMIT measured on the board (AGENTS #20, 3 boots): a push whose W beat is
        paired with another store's address can be *forged* with a foreign id while
        a foreign record reuses the same 4-bit tag, so ``retries=0`` and the record
        is still lost (``loss=[8]`` in 3 of 3 boots).  This confirms the command
        reached the FIFO -- it is not an id-level proof, and an incremental epoch
        stays best-effort: use a full mark when exactness matters.
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
