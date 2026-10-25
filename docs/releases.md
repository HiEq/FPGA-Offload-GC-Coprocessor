# 发布记录：改了什么、验证到哪里、已知边界

Release 页面只保留本页链接与资产哈希；逐版本的变化、证据和边界写在这里。
证据日志在 [`tools/logs/`](../tools/logs/README.md)，每份文件头写明命令、位流、BOOT 哈希、提交与日期。

| 版本 | 日期 | 一句话 | tag |
|---|---|---|---|
| v4.5 | 2026-10-25 | 数据寄存器写后校验（根集可读回） | `a02f7ada` |
| v4.4 | 2026-10-25 | 命令写携带目的地址标记 | `3a902b20` |
| v4.3 | 2026-10-24 | cmdfifo 同拍 enqueue 门控进入镜像 | `23c7cc8b` |
| v4.2 | 2026-10-24 | 硬件 GC 标记（Phase 3A/3B） | `cc2f02b` |
| v4.1 | 2026-10-20 | PL flush 修复（`run_start`/`abort` + 命令 FIFO） | `f9a6b5b` |

---

## v4.5

**改了什么**

- `rtl/gc_regs.v`、`rtl/gc_top.v`：根集 `0x040–0x43F` 增加读回通道（`root_rd_idx` / `root_rd_data`），此前只写。
- `csrc/fpga_gc.c`：新增 `reg_wr_verified()`，`OBJ_BASE` / `OBJ_COUNT` / `ROOT_COUNT` / 每个根都“写 → 回读 → 重试（最多 4 次）”，失败打印 ERROR。数据寄存器被 AW/W 错配写坏时会被发现并重写。
- `VERSION` → `0x0004_0301`。
- 卡上二进制与测试脚本随之重建；`card-userdata.zip` 因此变化。

**验证**

- 冷启动 `D1..D6=0`、`test_main` 3/3、`VERSION=0x0004_0301`、卡上 `BOOT.BIN` 与发布资产一致。
- 全链：`PHASE2_PASS`、`CONTRACT_RESULT OK`、`DIRTY_SET/CONCURRENT/OVERFLOW/CTRL_SPILL`、`DIRTY_STATE occ=0`、`DIRTY_API`、`FREELIST4096`、`run_gc` 8/8、`abort` T1–T5、`abort_sweep` 11/11、`done_race` P3 20/20、`repeat`、`irq`、`three_way`。
- `regs_aww`：冷轮 `--plain` / `--acked` 均 `loss=[] forged=[]`，暖轮 `loss 0/14`、多标 `0/14`，`--verify-effect` round 0 无需回退。
- 仿真：六套件全绿，`tb_gc_top` 新增根集回读检查（`root readback OK (7)`）。

**已知边界**

- 时序裕量很紧：WNS/WHS 均 `+0.049 ns`（根集读通道增加了一条路径），满足约束但接近临界。
- `DIRTY_PUSH` 的 28 位巧合（外来 store 恰好带 `0xA54` 标记且 `(tag,id)` 相同）仍无法从设备侧区分；当前寄存器集合里没有能凑出该模式的写，因此不可达。
- 根集读回只在引擎空闲时使用（驱动在写根后、启动前读）；并发读根会与引擎争用同一读端口。

---

## v4.4

**改了什么**

- `rtl/gc_regs.v`：`CTRL`(0x000) 要求 `WDATA[31:20] = 0xA50`，`DIRTY_PUSH`(0x440) 要求 `0xA54`；不匹配的 W 拍照常应答但丢弃。
- 平台把 W 拍错配到别的 AW 时，不再误触发 START/ABORT，也不会变成伪造的推送记录。
- `VERSION` → `0x0004_0300`；驱动、头文件、14 个板级测试、3 个 testbench 同步（`GC_CTRL_MARK` / `GC_PUSH_MARK`）。

**验证**

- 冷启动 `D1..D6=0`、`test_main` 3/3、`VERSION=0x0004_0300`。
- 全链绿；`regs_aww` 冷窗口从 `loss=[8]` 变为 `loss=[]`，暖机多标从 10–14/14 变为 0/14。
- `tb_regs_aww` 的 P4/P6 是负控：无标记的 W 不产生记录、不触发 START。

**已知边界**

- 数据寄存器（当时的 `OBJ_BASE`/`OBJ_COUNT`/`ROOT_LIST`）不带标记，错配表现为错误的值——由 v4.5 的写后回读补上。
- 28 位巧合同 v4.5。

---

## v4.3

**改了什么**

- RTL：命令 FIFO 的两条 enqueue 路径加 `!run_start && !abort`，同拍 `cmd_valid` 不再越过重载后的读写指针（AGENTS #17 第二阶段）。
- 位流重建并重打 `BOOT.BIN`；此前的镜像不含该门控。

**验证**

- 仿真定向测试 `tb_cmdfifo_flush` 第二阶段（未修复 `c0r=4 c0w=5` / `c1r=0 c1w=1`，修复后 `c0r==c0w`、`c1r==c1w`）。
- 板级：冷启动 `D1..D6=0`、`test_main` 3/3；`abort` T1–T5、`abort_sweep` 11/11、`done_race` P3 20/20、`run_gc` 8/8、`irq`、`regs_aww` A/B、`three_way`。

**已知边界**

- 门控本身是同一拍的竞态，板级只能证明“没有回归”；该竞态的证据是仿真。
- 平台的 AW/W 错配仍未处理（v4.4/v4.5 才加标记与回读）。

---

## v4.2

**改了什么**

- Phase 3A/3B：脏集 FIFO、并发增量标记、`CTRL[4]=BM_KEEP`、`CTRL[5]=DIRTY_FLUSH`（武装式）、id 级回执。

**验证**

- 冷启动与全链证据见 `tools/logs/`（v4.2 那一版已随镜像更新退役，可 `git log -- tools/logs/` 取回）。

**已知边界**

- 平台的 AW/W 错配（AGENTS #20）在当时只有软件侧的 id 回执与按效果验收缓解；根因见 v4.4/v4.5。
- 推送计数不精确（重投递 + 4 位 tag），语义安全。

---

## v4.1

**改了什么**

- `gc_top.v`：`gc_axi_read.run_start` 改为 `w_start & w_engine_idle`，忙时到达的 START 不再清掉进行中 epoch 的读通路。
- `gc_axi_read.v`：数据 FIFO 的 pop 在 `run_start`/`abort` 同拍被门控；`flushing` 退出条件加上 `!ARVALID`，已发出未握手的 AR 等回来再丢弃。
- 命令 FIFO 的 `issue_any` 在 `run_start`/`abort` 同拍被门控（AGENTS #17 第一阶段）。

**验证**

- `sim/run_cmdfifo_tb.bat`：未修复 RTL 残留 `ARADDR=0x30000008`，修复后无残留；`run_race_tb` / `run_sim` / `run_axi_tb` PASS。
- 板级：`test_main` 4/4、`run_gc` 8/8、`abort` T1–T5、`abort_sweep` 11/11、`done_race` P3 20/20。

**已知边界**

- 平台的 AW/W 错配当时未处理（v4.4 起加标记）。
- 该版 `card-userdata.zip` 与后续版本不同（v4.1 的卡上二进制）。

---

## 共同边界（所有版本）

Release 页面只保留本页链接和资产哈希表；变更、验证与边界的正文写在这里。

- 平台会重投递每一次 AXI-Lite 写，且副本不总是相邻；从设备侧无法把 W 拍归属到某个 store。命令写标记与写后回读是当前能做的两层防护。
- `DIRTY_PUSH` 的残余暴露面是一个 28 位巧合；彻底消除需要端到端 ack（硬件发一次性令牌、软件回写、硬件确认），当前未实现。
- 板上没有 RTC、没有网络；时间戳由宿主脚本注入。
