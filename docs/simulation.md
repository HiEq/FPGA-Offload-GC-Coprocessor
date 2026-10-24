# 仿真回归

> 主 [`README.md`](../README.md) 的「4. 正确性、性能与测量」只给结论；本文件是完整用例矩阵与反向验证。

`sim\run_sim.bat`（Windows）或 `sim/run_sim.sh`（Linux，需 `VIVADO_BIN`）**只跑 `tb_gc_top`**，
覆盖下面的主用例、T1–T8、T-FREE、T-DIRTY、T-DIRTY-RACE、T-ABORT/T-ABORT2、T-MAXFAN/T-ROOTCLAMP/T-STAR 和 AXI 协议检查。
定向回归要单独跑：

- `sim\run_axi_tb.bat` / `sim/run_axi_tb.sh` —— `tb_axi_read`（未完成读事务上限）
- `sim\run_race_tb.bat` / `sim/run_race_tb.sh` —— `tb_runstart_race`（同拍旧 R beat）
- `sim\run_cmdfifo_tb.bat` / `sim/run_cmdfifo_tb.sh` —— `tb_cmdfifo_flush`（同拍命令 FIFO）
- `sim\run_regs_aww_tb.bat` —— `tb_regs_aww`（`gc_regs` 的 AW/W 配对契约；`P4` 只打印 AGENTS #20 的引脚级上限）

`tools\reproduce_all.ps1` 串起 manifest、PS 单测和**五组 xsim**：
`tb_gc_top` / `tb_axi_read` / `tb_runstart_race` / `tb_cmdfifo_flush` / `tb_regs_aww`。

| 检查 | 内容 |
| --- | --- |
| 主用例 | N=300 / 活跃 250 / 孤岛 50；标记数、队列尾、位图逐位比对 |
| STATUS | `0x20` 的错误位 [3:0] 必须为 0，且 [4]=1（引擎 idle）|
| **T1** | 连续两次运行：`marked` 两次都必须是 2 |
| **T2** | 重复根（同一 root 写两次）：只算一次 |
| **T3** | 流水 AW（AW/W 背靠背两笔写）：两笔都必须落到正确寄存器 |
| **T4** | 非法对象头（`ref_count=0xFFFFFFFF`）：被拒、`STATUS[3]=1`、`marked` 仍是活跃区 |
| **T5** | 12 位寄存器地址：`root[60]` 在 `0x130`；写地址截断到 8 位会标记 0 个对象 |
| **T6** | **位图探针**：`0x24/0x28` 读回必须与 BRAM 内容逐字一致；邻近编码的对象必须读出 0 |
| **T-FREE** | **free-list 端到端**（引擎→位图→扫描器→`0x38/0x3C`）：64 对象星形图标记 {0..31}，`FREE_COUNT` 必须 =32，`FREE_DATA` 弹出的集合必须恰好 {32..63}。扫描器逐对象读 `mem[o]` 的第 `o%32` 位——打包布局（`o>>5`,`o&31`）漏检时报 62/集合错 |
| **T-DIRTY** | **脏集作为工作来源**（`0x440`~`0x450`）：无根 + 脏 {0,40,41} → `marked=6`、`DIRTY_DRAINED=PUSHED=POPPED=3`、free=58 且不含已标对象；`BM_KEEP` 下**已标容器强制重扫**（obj0 新增引用 10 必须被标）；256 深 FIFO 溢出置位 + flush 清除。负控 A0：无屏障 → `marked=0` |
| **T-DIRTY-TAG** | **带标签推送去重**：同一标签连写两遍（模拟本板写路径的重复投递）→ 只入队 1 条；换标签 → 正常接受（`pushed=2`）。这是"推送 == 屏障事件"的唯一保证 |
| **T-DIRTY-RACE** | **记录落在终止判定同拍**（`force` 注入到 `S_DONE` 判定拍）：记录必须留在 FIFO（占用=1）并被 remark epoch 消费（`drained=1`，目标 obj60 被标）。负控 RACE2：remark 前 flush → 目标漏标（协议规则的反证）|
| **T7** | **队列溢出**：强制 `q_full` 后 `STATUS[0]=1`，且 `marked=0`（不静默丢对象） |
| **T8** | **AXI 读错误**：注入 `RRESP=SLVERR` 后 `STATUS[1]=1`，且引擎不挂死 |
| **T-ABORT** | `CTRL[3]` 把挂死的引擎拉回 `S_IDLE` 并清 `DONE`；随后可再次完整运行 |
| **T-ABORT2** | **abort 后只写 `START`（不写 `CLEAR_Q`）**：队列/流水线里上一轮的残留必须已被 abort 丢弃，新图只标出它自己的活跃集、`STATUS=0x10`（idle、无错误）|
| **T-RACE** | **`run_start`/`abort` 同拍 R beat**：flush 当拍到达的旧响应必须被丢弃；未修复时数据 FIFO 留下上一轮的字，新 run 的第一笔 ref 被顶掉。每次必须命中 `RREADY=0` 窗口，未命中直接 FAIL（`sim/run_race_tb.bat` / `.sh`）|
| **T-CMDFIFO** | **`run_start`/`abort` 同拍命令 FIFO**：同拍不能再发下一条 AR；未修复时 `c0r=1→2` 且残留 `ARADDR=0x30000008`，修复后 `c0r=1→4`、无残留（`sim/run_cmdfifo_tb.bat` / `.sh`）|
| **T-MAXFAN** | 单个对象 **`ref_count=4095`**：引用 FIFO 顶到 80 深，对象头流仍必须排空（共享 R 通道不死锁），`marked` 精确、`STATUS=0x10` |
| **T-ROOTCLAMP** | **`root_count=0xFFFFFFFF`**：硬件必须钳到 256（`root_rd_addr` 只有 8 位），跑完且 `marked=256` |
| **T-STAR** | **4096 对象星形图**（root 0 → 1..4095）：`marked=4096`、`q_tail=0`（12 位指针回绕）、`STATUS=0x10` |
| **#6** | 未完成读事务数（outstanding AR）任何时刻 ≤ `MAXO`(8) |
| **AXI** | 协议检查器：`ARSIZE=3`/`ARLEN=0`/`ARBURST=INCR`/8 字节对齐/`ARID≤1`/`VALID` 在 `READY` 前不许撤销且载荷稳定 |

> 反向验证（全部实测过）：去掉对应修复后 —— T1 变 `marked=1`、T3 死锁超时、
> T4 超时、T5 变 `marked=0`、把 `ARSIZE` 改成 `2` 会报 1588 条 `[AXI][FAIL]`
> （而功能用例**照样通过**，因为存储模型不检查 ARSIZE）。
> T6/T7/T8 的反向验证：把 `0x28` 读回改成常量 → T6 报 2 处 FAIL；把 `err_ovf`
> 赋 0 → T7 `STATUS[0]=0`；把读主控的 `err` 去掉 → T8 `STATUS[1]=0`。
> T-FREE 的反向验证：把 `gc_freelist` 换回打包布局（读 `mem[o>>5]` 的第 `o%32` 位）→
> T-FREE 报 `FREE_COUNT=62 != 32`、弹出集合 lo=31/hi=1；板级同症状：n=512 时 `FREE_COUNT=496 != 128`。
> T-DIRTY 的反向验证：A0（去掉屏障 → `marked=0`）、B（按根路径去重 → obj10 漏标）、
> RACE2（remark 前 flush → obj60 漏标）——三段都在同一 TB 内断言"必须发生的后果"。
> 板级反向对照：新 `test_main` 跑在**旧比特流**上时，位图读回全部对不上
> （`bitmap readback=8 != MARKED=9`），换新比特流后 4/4 PASS。