# 设计细节：架构、脏引用增量标记、AXI 清理、中断

主 [`README.md`](../README.md) 只保留寄存器映射、关键参数与对象图布局；展开说明在这里。

## 架构与工作流

```
+---------------------------------------------------------------------------------+
| Zynq-7000 XC7Z100                                                               |
| PS (ARM Cortex-A9 x2 @ 800 MHz)        PL (FCLK0 = 100 MHz)                     |
|   host app / SW GC                       gc_top                                 |
|   fpga_gc.c    -- AXI-Lite -------->     |- gc_regs          registers          |
|   fogccc.py                              |- gc_mark_engine   BFS FSM            |
|   /dev/mem mmap -- AXI HP (64-bit) ->    |- gc_bitmap        4096x32            |
|                                          |- gc_queue         4096x12            |
|                                          |- gc_freelist      free scan          |
|                                          |- gc_dirty_fifo    dirty-edge source  |
|                                          `- gc_axi_read      dual-stream reader |
|                                                                                 |
| DDR3 0x1E000000: object graph (written by the host)                             |
+---------------------------------------------------------------------------------+
```

1. 宿主把对象图写入 DDR `0x1E000000`。
2. 驱动写 AXI-Lite 寄存器启动标记引擎。
3. 引擎做 BFS 标记；PS 轮询 `CTRL[31]=done`。
4. 宿主读 `MARKED` / 位图 / free-list，决定回收。

第 1 步与回收动作由调用者负责；本仓库不接入任何语言运行时。读写路径见
`csrc/fpga_gc.c`、`python/fogccc.py`。

## 脏引用与增量标记（Phase 3A/3B）

`gc_dirty_fifo` 是引擎的第二工作源：写 `0x440` 推入一个对象 ID。

- 位图未标 → 置位并计数；已标 → 强制重扫，不重复计数。
- `S_DONE` 还要求 FIFO 为空。
- 满 256 时丢弃并置 `0x444[9]`（粘滞）；软件见该位必须退回**全标记**。
- 推送是带标签命令：`0x440 = 0xA5400000 | (tag<<12) | id`，tag 每次逻辑推送必须变化；
  `WDATA[31:20]` 的 `0xA54` 是目的地址标记，见下面的“命令写标记”。

**epoch**：

1. **全标记**：`CTRL[5]`（仅预置 flush）+ 一次 `BM_KEEP=0` 的 `START` → 清位图与 FIFO，从根集全标。
2. **增量步**：`CTRL = 0x11`（`BM_KEEP` 与 `START` 同一次写），不 flush；mutator 可并发推送。
3. **remark**：mutator 停止后再来一个增量 epoch（根集可空），消费与 `DONE` 同拍到达的记录。
   remark 前不 flush。

**命令写标记**：`CTRL`(0x000) 与 `DIRTY_PUSH`(0x440) 的写数据高 12 位必须分别带 `0xA50` / `0xA54`。
本平台的 AXI-Lite 写通道会把一个 W 拍配到另一条 store 的 AW 地址上；标记不匹配时 `gc_regs` 照常应答但**丢弃**这次写，
所以错配的拍不会触发 START/ABORT，也不会变成伪造的推送。数据寄存器（OBJ_BASE 等）不带标记，错配只表现为一次错误的值，由测试覆盖。
`VERSION=0x0004_0301` 起强制该约定；同一版把根集（`0x040`–`0x43F`）改成可读，驱动写后回读并重试，数据寄存器错配由此可检测。

**屏障顺序**：先让指针存储对 PL 可见（写完回读/屏障），再写 `0x440`。

**`CTRL[5]` 为预置式 flush**：写入仅预置，在下一次 `BM_KEEP=0` 的 `START` 生效，被增量 start 丢弃。
因此迟到的 store 副本至多提前预置下一次全标记，不会清除当前 epoch 的记录。
清 FIFO 而不动位图时使用 `CLEAR_Q`，不使用 flush。

**确认一条记录真的进了 FIFO**：`DIRTY_STAT[31:20]` 是最后接受的 ID，与 `[19:16]` 的 tag 组成 按 id 回执。
`dirty_push_acked()` / `fpga_gc_dirty_push_acked()` 写一条、回读 tag+id，不匹配换 tag 重试；
重试用尽或溢出位被置 ⇒ 返回 0，调用者退回全标记。
`barrier_verify()` / `fpga_gc_read_mark()` 按效果校验：全标 ⇒ 未发现漏标；有未标 ⇒ 退回全标记。
后者是**必要非充分**检查：epoch 之前已标记的目标无法反映本次是否重扫。

**溢出路径**：忽略 `0x444[9]` 继续增量会漏标（`dirty_overflow_test.py` 的负控）；
退回全标记后 `marked == oracle`、`free` 正确、flush 后 `ovf=0`。

**写路径重投递**：本板每个 store 投递两遍且不保证相邻。`gc_top` 用 `engine_idle` 门控软件
`CLEAR_Q`，`gc_mark_engine` 在接受 `START` 时自行脉冲 `q_clear`，故迟到的 `CLEAR_Q` 不会中途清队列，
迟到的 `START` 只是一次冗余执行，且仍满足 `q_tail == marked`（`ctrl_spill_test.py`）。

**软件接口**：`fpga_gc_dirty_push` / `dirty_flush` / `dirty_status|drained|pushed|popped` /
`fpga_gc_mark_incremental`（保留位图、不 flush），以及 ctypes 绑定中的同名方法。
驱动维护递增 tag；屏障记录由调用者推入，与宿主语言无关。

## AXI 读流水线清理

`gc_axi_read` 在 `run_start` / `abort` 时清空命令与数据 FIFO，逐拍丢弃在途响应，
直到两条流的在途计数归零才发新命令。

- 消费者出队在 `run_start` / `abort` 同拍让位给 flush（不留残余拍）。
- `flushing` 只有在 `!ARVALID` 时退出，已发未握手的 AR 也会被等掉并丢弃响应。
- `gc_top` 只在 `engine_idle` 时把 `START` 传给读通道，被 FSM 忽略的 busy `START` 不会触发 flush。

定向用例：`sim/tb_flush_data.v`、`tb_stale_ar_flush.v`、`tb_start_while_busy.v`；
负控（修复前 RTL）三个全 FAIL，见 `tools/logs/xsim_handover_neg_20261024.log`。

## 中断链路（仅验证用）

`gc_top.irq_o = done` 接到 `ps7_0/IRQ_F2P[0]`，即 GIC 中断 ID 61（`ISPENDR1` bit 29）。

```
insmod fogccc-irq.ko          # 映射 SPI 61 + request_irq，生成 /dev/fogccc_irq
echo arm > /dev/fogccc_irq    # done=0 时不会触发
python3 fpga_vs_python.py 1024 1 2 --seed 11
cat /dev/fogccc_irq           # "1 0 <virq>"：已触发，处理函数自动关线
```

前提是 PL 刚配置（`done=0`）；`done=1` 时插模块会先计一次中断。测试必须在重启后第一条运行
（[`board-usage.md`](board-usage.md)）。两处约束见 [`driver/README.md`](../driver/README.md)。
