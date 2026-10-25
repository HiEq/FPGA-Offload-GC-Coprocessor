# 发布记录：变更内容、验证结果与已知限制

Release 页面仅保留本页链接与资产哈希表；逐版本的变更内容、验证结果与已知限制见下文。
证据日志位于 [`tools/logs/`](../tools/logs/README.md)，每份文件头记录命令、位流、BOOT 哈希、提交与日期。

| 版本 | 日期 | 摘要 | tag |
|---|---|---|---|
| v4.6 | 2026-10-25 | 位图探针地址写后校验（仅 USERDATA） | `PENDING` |
| v4.5 | 2026-10-25 | 数据寄存器写后校验（根集可读回） | `a02f7ada` |
| v4.4 | 2026-10-25 | 命令写携带目的地址标记 | `3a902b20` |
| v4.3 | 2026-10-24 | cmdfifo 同拍 enqueue 门控进入镜像 | `23c7cc8b` |
| v4.2 | 2026-10-24 | 硬件 GC 标记（Phase 3A/3B） | `cc2f02b` |
| v4.1 | 2026-10-20 | PL flush 修复（`run_start`/`abort` + 命令 FIFO） | `f9a6b5b` |

---

## v4.6

**变更内容**

- `csrc/fpga_gc.c`：`fpga_gc_read_mark()` 的探针地址写改为经 `reg_wr_verified()`（写入 → 回读 → 重试），失败返回 `0xFFFFFFFF`。`barrier_verify()` 依赖该探针，此前一次 AW/W 错配就可能探测到错误对象，从而漏判“未重扫”。
- 仅重新编译 USERDATA 侧二进制；`BOOT.BIN`、位流与 `VERSION=0x0004_0301` 均未变化。

**验证结果**

- 板上（v4.5 镜像）：`test_main` 3/3、`regs_aww --verify-effect` `VERIFY_EFFECT_RESULT OK`（0/14 需回退）、`dirty_api_test` `DIRTY_API_RESULT OK`（含 `acked push`）。
- 位流与 BOOT 未变，冷启动证据沿用 v4.5（`board_coldboot_verify_20261025_v45.log`）。

**已知限制**

- 探针校验失败时返回 `0xFFFFFFFF`，由调用方按“未知”处理：`barrier_verify()` 会退回全标记（安全方向），`dump_marks()` 会打印异常值（可见）。不是硬错误。
- 其余限制同 v4.5。

---

## v4.5

**变更内容**

- `rtl/gc_regs.v`、`rtl/gc_top.v`：根集 `0x040–0x43F` 增加读回通道（`root_rd_idx` / `root_rd_data`），此前为只写。
- `csrc/fpga_gc.c`：新增 `reg_wr_verified()`，`OBJ_BASE` / `OBJ_COUNT` / `ROOT_COUNT` 及每个根均执行“写入 → 回读 → 重试（最多 4 次）”，失败时输出 ERROR。数据寄存器因 AW/W 错配写入错误值时，该值会被检出并重写。
- `VERSION` 更新为 `0x0004_0301`。
- 卡上二进制与测试脚本随之重建；`card-userdata.zip` 因此变化。

**验证结果**

- 冷启动 `D1..D6=0`、`test_main` 3/3、`VERSION=0x0004_0301`、卡上 `BOOT.BIN` 与发布资产一致。
- 全链：`PHASE2_PASS`、`CONTRACT_RESULT OK`、`DIRTY_SET/CONCURRENT/OVERFLOW/CTRL_SPILL`、`DIRTY_STATE occ=0`、`DIRTY_API`、`FREELIST4096`、`run_gc` 8/8、`abort` T1–T5、`abort_sweep` 11/11、`done_race` P3 20/20、`repeat`、`irq`、`three_way`。
- `regs_aww`：冷启动轮次中 `--plain` 与 `--acked` 均为 `loss=[] forged=[]`；暖机轮次 `loss 0/14`、多标 `0/14`；`--verify-effect` 的 round 0 无需回退。
- 仿真：六套件全部通过；`tb_gc_top` 新增根集回读检查（`root readback OK (7)`）。

**已知限制**

- 时序裕量较小：WNS/WHS 均为 `+0.049 ns`（根集读通道增加了一条路径），满足约束但接近临界。
- `DIRTY_PUSH` 的 28 位巧合（外部 store 恰好携带 `0xA54` 标记且 `(tag,id)` 相同）仍无法从设备侧区分；当前寄存器集合中不存在可产生该模式的写操作，因此不可达。
- 根集读回仅在引擎空闲时使用（驱动在写入根集之后、启动之前读取）；若在运行中并发读取，将与引擎争用同一读端口。

---

## v4.4

**变更内容**

- `rtl/gc_regs.v`：`CTRL`(0x000) 要求 `WDATA[31:20] = 0xA50`，`DIRTY_PUSH`(0x440) 要求 `0xA54`；不匹配的 W 拍仍返回应答，但该写被丢弃。
- 当平台把 W 拍与另一条 store 的 AW 错配时，不再误触发 START/ABORT，也不会产生伪造的推送记录。
- `VERSION` 更新为 `0x0004_0300`；驱动、头文件、14 个板级测试与 3 个 testbench 同步（`GC_CTRL_MARK` / `GC_PUSH_MARK`）。

**验证结果**

- 冷启动 `D1..D6=0`、`test_main` 3/3、`VERSION=0x0004_0300`。
- 全链通过；`regs_aww` 冷启动轮次由 `loss=[8]` 变为 `loss=[]`，暖机多标由 10–14/14 变为 0/14。
- `tb_regs_aww` 的 P4/P6 为负控：无标记的 W 不产生记录，也不触发 START。

**已知限制**

- 数据寄存器（当时的 `OBJ_BASE`/`OBJ_COUNT`/`ROOT_LIST`）不带标记，错配表现为错误的值；该问题由 v4.5 的写后回读覆盖。
- 28 位巧合同 v4.5。

---

## v4.3

**变更内容**

- RTL：命令 FIFO 的两条 enqueue 路径增加 `!run_start && !abort`，同拍 `cmd_valid` 不再越过重载后的读写指针（AGENTS #17 第二阶段）。
- 位流重建并重新打包 `BOOT.BIN`；此前的镜像不包含该门控。

**验证结果**

- 仿真定向测试 `tb_cmdfifo_flush` 第二阶段（未修复时 `c0r=4 c0w=5` / `c1r=0 c1w=1`，修复后 `c0r==c0w`、`c1r==c1w`）。
- 板级：冷启动 `D1..D6=0`、`test_main` 3/3；`abort` T1–T5、`abort_sweep` 11/11、`done_race` P3 20/20、`run_gc` 8/8、`irq`、`regs_aww` A/B、`three_way`。

**已知限制**

- 门控本身是同一拍的竞态，板级验证只能证明未发生回归；该竞态的证据来自仿真。
- 平台的 AW/W 错配尚未处理（v4.4/v4.5 才引入标记与回读）。

---

## v4.2

**变更内容**

- Phase 3A/3B：脏集 FIFO、并发增量标记、`CTRL[4]=BM_KEEP`、`CTRL[5]=DIRTY_FLUSH`（武装式）、id 级回执。

**验证结果**

- 冷启动与全链证据见 `tools/logs/`（该版本对应的日志已随镜像更新退役，可通过 `git log -- tools/logs/` 取回）。

**已知限制**

- 平台的 AW/W 错配（AGENTS #20）在当时仅有软件侧的 id 回执与按效果验收作为缓解；根因见 v4.4/v4.5。
- 推送计数不精确（重复投递 + 4 位 tag），该行为在语义上是安全的。

---

## v4.1

**变更内容**

- `gc_top.v`：`gc_axi_read.run_start` 改为 `w_start & w_engine_idle`，在引擎忙时到达的 START 不再清除进行中 epoch 的读通路。
- `gc_axi_read.v`：数据 FIFO 的 pop 在 `run_start`/`abort` 同拍被门控；`flushing` 退出条件增加 `!ARVALID`，已发出但未握手的 AR 等待返回后再丢弃。
- 命令 FIFO 的 `issue_any` 在 `run_start`/`abort` 同拍被门控（AGENTS #17 第一阶段）。

**验证结果**

- `sim/run_cmdfifo_tb.bat`：未修复 RTL 残留 `ARADDR=0x30000008`，修复后无残留；`run_race_tb` / `run_sim` / `run_axi_tb` 均 PASS。
- 板级：`test_main` 4/4、`run_gc` 8/8、`abort` T1–T5、`abort_sweep` 11/11、`done_race` P3 20/20。

**已知限制**

- 平台的 AW/W 错配在当时未处理（v4.4 起引入标记）。
- 该版本的 `card-userdata.zip` 与后续版本不同（对应 v4.1 的卡上二进制）。

---

## 通用限制（所有版本）

Release 页面仅保留本页链接和资产哈希表；变更内容、验证结果与限制的正文记录在此。

- 平台会重复投递每一次 AXI-Lite 写，且副本不总是相邻；从设备侧无法将 W 拍归属到具体的 store。命令写标记与写后回读是目前可用的两层防护。
- `DIRTY_PUSH` 的残余暴露面是一个 28 位巧合；彻底消除需要端到端确认机制（硬件生成一次性令牌、软件回写、硬件校验），当前未实现。
- 板上没有 RTC，也没有网络；时间戳由宿主脚本注入。
