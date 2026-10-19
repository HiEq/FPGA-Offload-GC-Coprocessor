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
#define REG_VERSION      0x34   // fixed 0x0004_0000 (v4.0)
#define FOGCCC_MAGIC     0x47434343u
#define FOGCCC_VERSION   0x00040000u

// STATUS bit masks
#define STATUS_OVF       (1U << 0)   // queue full, object dropped
#define STATUS_RDERR     (1U << 1)   // AXI read response error
#define STATUS_REFDESYNC (1U << 2)   // consumed more refs than issued
#define STATUS_HDR       (1U << 3)   // ref_count > 4096 (corrupt header)

// ==================== CTRL寄存器位定义 ====================
#define CTRL_START       (1U << 0)   // 启动标记
#define CTRL_CLEAR_BM    (1U << 1)   // 未使用: 位图由引擎每轮自动清除
#define CTRL_CLEAR_Q     (1U << 2)
#define CTRL_ABORT       (1U << 3)   // 把引擎拉回 IDLE 并清 DONE（超时后复位用）   // 清BFS队列
#define CTRL_DONE        (1U << 31)  // 完成标志

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

// 软件BFS标记 (对照组, 验证正确性)
uint32_t fpga_gc_sw_mark(fpga_gc_t *dev, uint32_t *roots, int n_roots);
/* same BFS, but also writes the per-object bitmap into out[0..obj_count-1] */
uint32_t fpga_gc_sw_mark_bits(fpga_gc_t *dev, uint32_t *roots, int n_roots, uint8_t *out);

// 读取单个对象的标记状态
uint32_t fpga_gc_read_mark(fpga_gc_t *dev, uint32_t obj_id);

// 打印标记位图
void fpga_gc_dump_marks(fpga_gc_t *dev, int n);

// 清除位图和队列
void fpga_gc_clear(fpga_gc_t *dev);

// 打印硬件统计信息
uint32_t fpga_gc_status(fpga_gc_t *dev);
void fpga_gc_print_stats(fpga_gc_t *dev);

#endif // FPGA_GC_H
