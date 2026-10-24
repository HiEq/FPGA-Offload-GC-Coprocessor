# 设计细节：Phase 3A/3B、AXI 流水线清理、中断链路

> 主 [`README.md`](../README.md) 的「3. 设计与接口」只保留寄存器映射、关键设计参数与对象图布局；
> 需要展开的设计说明收拢到本文件。

## Phase 3A/3B：脏边驱动与增量标记

`gc_dirty_fifo` 给标记引擎加了一条「屏障记录」输入：写 `0x440` 推入一个被写对象的 ID，
引擎把它当工作来源——位图未标 → 置位并计数；**已标 → 强制重扫（不重复计数）**；
`S_DONE` 判据额外要求 FIFO 为空；队列满时**停等不丢**（根路径是 skip + `err_ovf`，
屏障记录不允许静默丢）。满 256 时丢弃并置 `0x444[9]` 溢出粘滞位——软件见溢出必须退回整堆标记。

**epoch 协议**（A/B 共用同一接口与寄存器，B 未改 RTL）：

1. **全标记周期**：写 `CTRL[5]`（只**武装** flush）+ 一次 `CTRL[4]=0` 的 `START` → 由该 start 清位图与脏 FIFO，从根集全标；
1b. **增量步之后必须按效果验收**（AGENTS #20）：mutator 对每个被重新指向的目标读一次位图（`fogccc.barrier_verify()` / C 的 `fpga_gc_read_mark`）——全标 ⇒ **未发现漏标**（视为可信）；有未标 ⇒ **退回第 1 步**。这是**必要而非充分**检查：目标若在 epoch
之前就已被标记，检查看不见它的重扫是否发生——所以要么只查“本轮新指向、此前未标”的目标，要么用完整 oracle/计数复核。代价：每个弄脏容器一次探针，快路径不为它付费。
1c. **快路径回执**（2026-10-23，AGENTS #20 F2）：`DIRTY_STAT[31:20]` 是 FIFO 最后接受的 **id**，与 `[19:16]` 的 tag 一起构成 id 级回执。`dirty_push_acked()` / `fpga_gc_dirty_push_acked()` 写一条、回读 tag+id，不匹配就换 tag 重试，重试用尽或 overflow 置位 ⇒ 返回 0，调用者**退回全标记**。于是丢记录从"静默"变成"可发现 + 有兜底"；伪造记录（多标）在该回执里表现为"id 不是我刚写的" ⇒ 同样会被重试掉。
2. **增量步**：`CTRL[4]=1`（**必须与 `[0]=start` 同一次写**：`CTRL=0x11`），且**不要 flush**；
   mutator 可并发写 `0x440`（接口与 A 相同）；
3. **remark（收口）**：mutator 停止后再来一个 `CTRL[4]=1` 的 epoch（根集可空）——它消费
   「恰好在引擎终止判定同一拍到达」的那条记录（该记录留在 FIFO 里等下一次 epoch）。
   **remark 前绝不 flush**：flush 会把那条记录丢掉（仿真 `T-DIRTY-RACE2` 就是这个负控）；
4. free-list 只在**周期末**有意义：未标记 = 本周期从未可达。

**屏障契约**：先让指针存储对 PL 可见（DDR 写完回读/屏障），**再**写 `0x440`；顺序反了会漏边。
推送是**带标签命令**：`0x440 = (tag<<12) | id`，`tag` 每次逻辑推送必须变化（从 `0x444[19:16]` 起序号最稳）。
本板 AXI-Lite 写路径把每次 store 投递两遍（8/16/32 位写实测均为 2 条记录；读不重复），
而且这两遍**不一定相邻**：标签未变的重复投递被忽略，但重投递若在标签已被下一条改掉之后
才到达，就会被当成**额外一条**接受。实测（`tools/out/tag_leak_probe*.log`）：**单次**
推送（K=1）也会偶发 `occ=2`，且与间隔无关（插入读回屏障、加 10 ms 间隔同样出现）。
**功能语义安全**：额外记录的 id 必然是已在集合里的 id 的重复——A 段实测 `occ=4` 而
`marked` 仍是 6（= `closure{0,40,41}`），A/D 与并发测试的 `marked==oracle` 全部精确；
受影响的只有计数与 FIFO 占用（≈每批 1~2 条；250 次逻辑推送实测 251~252）。
代价是 FIFO 接近满时可能触发一次**虚假溢出** → 按溢出路径退回全标记（安全，但白跑一次）。
因此软件用 `pushed ≥ 逻辑条数` 判"不丢"，不用等号。
硬件**不会**把接受规则收紧成"只接受 `tag == last+1`"：投递一旦乱序（t+1 先到、t 后到）
那样会**丢**一条屏障记录，比多算一条危险得多；要精确计数只能上推送应答握手（另案）。

**并发怎么被证明**（B）：增量 epoch 靠**热容器**种子的 150 次屏障写撑住——该对象引用表
1024 项，一次强制重扫要读满整张表（≈31 µs/次）⇒ epoch 存活 ≈5.4 ms（测试输出 `epoch2_window_us`）。
mutator 线程只在读到 `CTRL[DONE]==0` 时推一条并自增计数（不靠采样忙位）：板上
`live_pushes` 36~38/100，且 `drained(epoch2) ≈ 种子 + live_pushes`（188 ≈ 150+38），
其余落在 `DONE` 之后由 remark epoch 收口 —— 三轮计数恒等 `pushed == popped == drained`。

**证据**：仿真 `T-DIRTY`（A0/A/B/C 四段，含三处负控）与 `T-DIRTY-RACE`（+RACE2 负控）；
板上 `tests/dirty_set_test.py`（A：增量 epoch + oracle + 屏障缺失负控）与
`tests/dirty_concurrent_test.py`（B：并发 mutator + remark；校验 `marked==oracle`、`free=未标记`、
`pushed==popped==drained`、`pushed ≥ 种子+预算`（不丢）、无溢出、无 STATUS 错误位，
含 no-barrier 负控 `missed=142`）。

**全标记必须与 `CTRL[5]` 脏集 flush 同发**（脏 FIFO 跨进程存活；否则残留的屏障记录会让引擎重扫位图
刚被清掉的 id，多标 + `q_tail != marked`）：C 侧已按此修（`csrc/fpga_gc.c`、`csrc/cmark.c`），
定向负控 `tests/dirty_leftover_test.py` —— 旧二进制 + 2 条残留记录 ⇒ `q_tail=10 != marked=9` 失败，
修好后 `ALL PASS`（`tools/logs/board_phase3_leftover.log`）。

**`CTRL[5]` 是"武装式" flush（arm-and-consume，2026-10-23）**：CTRL 写只**武装** flush，
它在**下一次 `BM_KEEP=0` 的 START**（全标记，本来就要清 FIFO）上生效，并被**增量（`BM_KEEP=1`）start 丢弃**
（`rtl/gc_top.v` 的 `flush_armed` + `w_dirty_flush_eff`）。这样本板"每次 store 重投递两遍、副本不一定相邻"
（见上文）就不再能造成静默丢记录：迟到副本最坏只是把下一次全标记的 flush 提前武装。驱动不需要改写法——
它本来就是"写 `CLEAR_Q|DIRTY_FLUSH`，再写 `START`"。**软件契约**：`dirty_flush()`（C/Python 绑定）只武装，
必须紧跟一次全标记才生效；清 FIFO 而**不想动位图**时（如 BM_KEEP 之前的准备）用 `CLEAR_Q` 而不是 flush。

仿真证据（`sim/tb_gc_top.v`）：`T-DIRTY-FLUSHIDLE` / `T-DIRTY-FLUSHSPILL` / `T-DIRTY-RACE(rc2=1)`：
- 旧"仅空闲门控"RTL → `T-DIRTY-FLUSHIDLE` 失败（空闲裸 flush 把已推记录清掉）：
  `tools/logs/xsim_dirtyflushidle_ungated_20261023.log`
- arm-and-consume RTL → 三段全过（裸 idle flush 只武装、全标记 start 清空、增量 start 丢弃且记录被正常消费）：
  `tools/logs/xsim_dirtyflushidle_armconsume_20261023.log`

**溢出契约**：FIFO 满 256 时推入被丢弃并置 `0x444[9]` 粘滞位（不是静默丢）；软件见到该位必须退回**全标记**，
因为被丢弃的容器的目标在增量步里永远不会被扫到。板上 `tests/dirty_overflow_test.py`：并发中压满 ⇒
`occ=256`/`ovf=1`（逻辑 430 条 → 接受 350 / 丢弃 80；±1 的波动来自 #18/#20 的写路径行为）；
**负控**（忽略标志继续增量）⇒ `marked=832 != oracle=912`
（漏 80 个目标，证明退回是必须的）；**退回全标记** ⇒ `marked=912 == oracle`、`free=112`、`STATUS=0x10`、
flush 后 `ovf=0`（`tools/logs/board_phase3_dirty_overflow.log`）。

**冷启动证据**：位流用 bootgen 重打进 `BOOT.BIN`（sha256 `39fe1040…`；结构校验
`tools/debug/verify_bootbin.py` PASS；旧阶段 2 镜像重启 ⇒ `VERSION=0x00040100` 的控制实验证明 FSBL
每次启动都重配 PL），上电后 `VERSION=0x00040200`、`test_main` 4/4 与整条板上链（含 3A/3B/溢出/防护）
见 `tools/logs/board_coldboot_20261023.raw.log`。

**写路径重投递的防护（B）**：本板每个 store 会被重投递且不保证相邻，所以 `CTRL` 的两次写也可能在引擎运行中再次到达。
`gc_top` 现在用 `engine_idle` 门控软件 `CLEAR_Q`（迟到的清队列不会中途清空 BFS 队列），`gc_mark_engine` 在接受
`START` 时自己脉冲 `q_clear`（迟到的 `START` 触发冗余重跑也仍满足 `q_tail == marked`）。寄存器映射与接口**未变**
（`VERSION` 保持 `0x0004_0200`，卡上二进制继续配对）。仿真 `T-CTRL-SPILL` / `T-CTRL-RESTART`：未门控 RTL 报
`q_tail=198 != 200` 与 `q_tail=398 != 200`（3 errors），门控后全绿。
板上 `tests/ctrl_spill_test.py`（冷启动镜像）：运行中写 `CLEAR_Q` 与 `START` 均保持 `marked == q_tail == 200`
（`CTRL_SPILL_RESULT OK`）——这也是"卡上位流确实含防护"的功能性证据（`VERSION` 两版相同，分不出来）。

**软件接口**：C 驱动（`csrc/fpga_gc.h`）与 ctypes 绑定（`python/fogccc.py`）都已暴露阶段 3A 的
`fpga_gc_dirty_push` / `dirty_flush` / `dirty_status|drained|pushed|popped` 与 `fpga_gc_mark_incremental`
（保留位图、**不** flush）。屏障记录由**调用者**推入——任何 mutator 都行，与宿主语言无关；驱动内部维护
变化的 tag（本板写路径会重投递 store）。板级验收：`tests/dirty_api_test.py`（含 `--neg` 反向验证）。

## AXI 读流水线清理

`gc_axi_read` 在 `run_start` 时清空命令 FIFO 与数据 FIFO，
并逐拍丢弃在途响应，直到两条流的在途计数归零才发新命令。
覆盖：`done_race_test.py` P3（每轮 `STATUS[3:0]=0` 且 `[4]=1`；修复前为 `0x4`，并有一次标出 964/768）。

## 中断链路（仅作为验证测试使用）

`gc_top.irq_o = done` 接到 `ps7_0/IRQ_F2P[0]`，即 **GIC 中断 ID 61**
（`ISPENDR1` bit 29）。`driver/` 里有一个最小模块验证整条链路：

```
insmod fogccc-irq.ko          # 映射 SPI 61 + request_irq，生成 /dev/fogccc_irq
echo arm > /dev/fogccc_irq    # 使能（done=0 时不会触发）
python3 gc_test.py 1024 1 2 --seed 11   # done 0 -> 1
cat /dev/fogccc_irq           # "1 0 <virq>"  ← 中断已触发，处理函数自动关线
```

实测（发布镜像，PL 刚配置）：`before arm 0 0 / after arm 0 1 / after run 1 0`，`VERDICT: IRQ_DRIVEN_DONE_OK`
（`tools/logs/board_irq.log`）。前提是 PL 处于 `done=0`；若 `done=1`（跑过一次），插模块就会先计一次中断，测试会报 FAIL。
两处约束见 `driver/README.md`（hierarchy 域没有 `.map`；`fwspec.param[1]` 是
SPI 编号 = ID − 32）。