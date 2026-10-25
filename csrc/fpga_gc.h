// ============================================================
// fpga_gc.h — FOGCCC PS端驱动头文件
// 平台: Xilinx Zynq-7000 XC7Z100
//
// 编译: PetaLinux SDK 交叉编译
//       $CC -O2 -o test_main fpga_gc.c test_main.c
// 运行: sudo ./test_main
// ============================================================
#ifndef FPGA_GC_H
#define FPGA_GC_H

#include <stdint.h>
#include <stddef.h>

// ==================== XC7Z100 物理地址 ====================
// 地址取自 Vivado Block Design 的 PS7 配置
#define FPGA_BASE_ADDR   0x43C00000UL  // AXI-Lite GP0 基地址
#define GRAPH_DDR_ADDR   0x1E000000UL  // 对象图存放的DDR物理地址
#define MAP_SIZE         4096          // 寄存器映射大小 (4KB)
#define GRAPH_MAP_SIZE   0x100000      // 对象图映射大小 (1MB)

// ==================== 寄存器偏移 ====================
#define REG_CTRL         0x00   // 控制
#define REG_OBJ_BASE     0x04   // 对象图DDR基地址
#define REG_OBJ_COUNT    0x08   // 对象总数
#define REG_ROOT_COUNT   0x0C   // 根集数量
#define REG_MARKED       0x10   // 标记对象数 (只读)
#define REG_CYCLES       0x14   // 硬件周期数 (只读)
#define REG_Q_HEAD       0x18   // 队列头指针 (只读)
#define REG_Q_TAIL       0x1C   // 队列尾指针 (只读)
#define REG_ROOT_LIST    0x40   // 根集数组起始
#define REG_STATUS       0x20   // [0]=queue overflow [1]=AXI read error [2]=ref desync [3]=bad header
#define REG_BM_ADDR      0x24   // bitmap probe address (0..4095)
#define REG_BM_DATA      0x28   // bitmap probe data  = mem[BM_ADDR]
#define REG_MAGIC        0x30   // fixed 0x47434343 ("GCCC"): bitstream/software pairing
#define REG_VERSION      0x34   // fixed 0x0004_0301 (v4.5: root read-back + command markers)
#define REG_FREE_COUNT   0x38   // Phase 2: number of free ids in the PL list
#define REG_FREE_DATA    0x3C   // Phase 2: read pops one free id
#define REG_DIRTY_PUSH   0x440  // write 0xA5400000 | (tag<<12) | id (marker = WDATA[31:20])
#define REG_DIRTY_STAT   0x444  // [8:0] occupancy [9] overflow [10] pending [19:16] last tag
                                // [31:20] last accepted id (AGENTS #20 ack)
#define REG_DIRTY_DRAINED  0x448  // ids consumed in the current epoch
#define REG_DIRTY_PUSHED 0x44C  // ids accepted since the last flush
#define REG_DIRTY_POPPED 0x450  // ids consumed since the last flush
#define FOGCCC_MAGIC     0x47434343u
#define FOGCCC_VERSION   0x00040301u

// STATUS bit masks
#define STATUS_OVF       (1U << 0)   // queue full, object dropped
#define STATUS_RDERR     (1U << 1)   // AXI read response error
#define STATUS_REFDESYNC (1U << 2)   // consumed more refs than issued
#define STATUS_HDR       (1U << 3)   // ref_count > 4096 (corrupt header)
#define STATUS_IDLE      (1U << 4)   // engine FSM is in S_IDLE
#define STATUS_FREEBUSY  (1U << 5)   // Phase 2 free-list scanner owns the bitmap

// ==================== CTRL寄存器位定义 ====================
#define CTRL_START       (1U << 0)   // 启动标记
#define CTRL_CLEAR_BM    (1U << 1)   // 未使用: 位图由引擎每轮自动清除
#define CTRL_CLEAR_Q     (1U << 2)
#define CTRL_BM_KEEP     (1U << 4)   // Phase 3A: 保留位图 (增量 epoch; 必须与 START 同一次写)
#define CTRL_DIRTY_FLUSH (1U << 5)   // Phase 3A: 清脏集 FIFO + 溢出标志
#define CTRL_ABORT       (1U << 3)   // 把引擎拉回 IDLE 并清 DONE（超时后复位用）   // 清BFS队列
#define CTRL_DONE        (1U << 31)  // 完成标志
// Command writes must carry their destination in WDATA[31:20]: a mispaired
// W beat (platform AW/W reorder) then fails the check and is dropped.
#define GC_CTRL_MARK     0xA5000000u  // CTRL (0x000)
#define GC_PUSH_MARK     0xA5400000u  // DIRTY_PUSH (0x440)

// ==================== 对象图DDR格式 ====================
//
// 每个对象占 16 字节头, 引用数组在独立区域:
//
//   地址: obj_base + k*16
//   ┌──────────────────────────────────────┐
//   │ +0:  uint32 obj_id        对象索引   │
//   │ +4:  uint32 ref_count     引用数     │
//   │ +8:  uint32 ref_addr      引用数组物理地址
//   │ +12: uint32 reserved                  │
//   └──────────────────────────────────────┘
//   引用数组 (在 ref_addr 处):
//   ┌──────────────────────────────────────┐
//   │ [ref0][ref1]...[refN-1][0xFFFFFFFF] │
//   └──────────────────────────────────────┘
//
//   引擎地址计算:
//     1. 读头+4 获取 ref_count
//     2. 读头+8 获取 ref_array_phys_addr
//     3. 用 ref_array_phys_addr + j*4 读引用

// ==================== 驱动句柄 ====================
typedef struct {
    volatile uint32_t *regs;        // AXI-Lite寄存器虚拟地址
    int                fd;          // /dev/mem 文件描述符
    void              *graph_vaddr; // 对象图虚拟地址
    uint32_t           graph_paddr; // 对象图物理地址
    int                obj_count;   // 当前对象数
    // Phase 3A: DIRTY_PUSH is a command-with-tag; the tag must change per logical
    // push (the board redelivers stores). Appended at the end so the ctypes mirror
    // in python/fogccc.py stays byte-compatible.
    uint32_t           dirty_tag;       // next tag to use
    uint32_t           dirty_tag_valid; // 0 until the first push seeds it from 0x444
} fpga_gc_t;

// ==================== API函数 ====================

// 初始化: 打开/dev/mem, 映射寄存器和DDR
int  fpga_gc_init(fpga_gc_t *dev);

// 关闭: 解除映射
void fpga_gc_close(fpga_gc_t *dev);

// 构建n个对象的测试图到DDR
int  fpga_gc_build_graph(fpga_gc_t *dev, int n, int avg_refs);

// 设置根集 (根对象ID数组)
void fpga_gc_set_roots(fpga_gc_t *dev, uint32_t *roots, int n_roots);

// 启动FPGA标记, 等待完成
// 返回: 标记的对象数, 0xFFFFFFFF=超时
uint32_t fpga_gc_mark(fpga_gc_t *dev, uint32_t *cycles_out);

// Phase 3A: 增量 epoch —— 保留位图 (CTRL[4]=BM_KEEP) 且**不**清脏集 (remark 前绝不 flush)。
// 根集由调用者决定 (通常为空); 脏集记录由 fpga_gc_dirty_push() 推入。
uint32_t fpga_gc_mark_incremental(fpga_gc_t *dev, uint32_t *cycles_out);

// Phase 3A: 推入一条屏障记录 (写路径重投递 ⇒ 内部维护变化的 tag)
void     fpga_gc_dirty_push(fpga_gc_t *dev, uint32_t obj_id);
/* Push and confirm the FIFO accepted THIS id (0x444[31:20]/[19:16], AGENTS #20).
 * Returns 1 when confirmed, 0 when it could not be confirmed (sticky overflow or
 * the retry budget ran out): the caller must then fall back to a full mark.
 * Costs one register read per attempt; use it only where an epoch must be exact. */
int      fpga_gc_dirty_push_acked(fpga_gc_t *dev, uint32_t obj_id, int retries);
// Phase 3A: 清脏集 FIFO + 溢出标志 (全标记周期用; 增量/remark 前绝不能调)
void     fpga_gc_dirty_flush(fpga_gc_t *dev);
uint32_t fpga_gc_dirty_status(fpga_gc_t *dev);   // 0x444 原始值
uint32_t fpga_gc_dirty_drained(fpga_gc_t *dev);  // 本 epoch 已消费条数
uint32_t fpga_gc_dirty_pushed(fpga_gc_t *dev);   // 上次 flush 以来接受的条数
uint32_t fpga_gc_dirty_popped(fpga_gc_t *dev);   // 上次 flush 以来消费的条数

// 软件BFS标记 (对照组, 验证正确性)
uint32_t fpga_gc_sw_mark(fpga_gc_t *dev, uint32_t *roots, int n_roots);
uint32_t fpga_gc_sw_mark_cached(fpga_gc_t *dev, uint32_t *roots, int n_roots);
uint32_t fpga_gc_sw_mark_us(fpga_gc_t *dev, uint32_t *roots, int n_roots, int cached, double *us_out);
/* same BFS, but also writes the per-object bitmap into out[0..obj_count-1] */
uint32_t fpga_gc_sw_mark_bits(fpga_gc_t *dev, uint32_t *roots, int n_roots, uint8_t *out);

// 读取单个对象的标记状态
// 前置条件: 引擎 idle (STATUS[4]=1); 否则返回 0xFFFFFFFF
uint32_t fpga_gc_read_mark(fpga_gc_t *dev, uint32_t obj_id);

// 队列尾指针 (只读), 用于 q_tail == marked 的不变量检查
uint32_t fpga_gc_q_tail(fpga_gc_t *dev);

// 等待引擎回到 S_IDLE; 超时返回 -1
int fpga_gc_wait_idle(fpga_gc_t *dev, int timeout_us);
int fpga_gc_wait_freeidle(fpga_gc_t *dev, int timeout_us);
uint32_t fpga_gc_free_count(fpga_gc_t *dev);
uint32_t fpga_gc_free_pop(fpga_gc_t *dev);

// 打印标记位图
void fpga_gc_dump_marks(fpga_gc_t *dev, int n);

// 清除位图和队列
void fpga_gc_clear(fpga_gc_t *dev);

// 打印硬件统计信息
uint32_t fpga_gc_status(fpga_gc_t *dev);
void fpga_gc_print_stats(fpga_gc_t *dev);

#endif // FPGA_GC_H
