# tools/logs/ —— 证据日志

这里只放 **README / docs / Release 引用得到的最终一次有效测量**，不做流水账：
每个引用点一份、**文件名固定**，重跑直接覆盖（需要旧内容时从 git 历史取，`git log -- tools/logs/`）。

每个文件头部是溯源信息：

```
# command: <完整命令>
# bitstream: <md5>   boot.bin: <sha256>
# commit: <产生这些二进制的源码提交>
# date: <YYYY-MM-DD>
```

若生成日志的**测试脚本本身晚于 `commit`**（例如刚改完测试再上板），在头里补一行把脚本钉死：

```
# test: tools/tests/<name>.py md5 <md5>
```

二进制本身的哈希见 `artifacts/SHA256SUMS`（随卡二进制）与 `artifacts/SHA256SUMS.release`（Release 资产）。

**当前证据集**（位流 md5 `3332D8D631A8DB5D8091972DFEE5565E` / BOOT sha256 `ac8d31cc…` / `VERSION=0x0004_0200`；
> 历史负控（`*_neg_*`、`board_phase3_leftover`、`board_regs_aww_verified`、`board_regs_aww_probe_forge_*`）与 `xsim_*_20261022/23` 属各自测过的那一版，文件头保留原样；
> 2026-10-24：镜像由板端串口写入（本机工具，不入库；回读 sha256 一致），断电上电后落在 fogccclinux 完成复验与全套回归。
> `board_phase3_dirty_api.log` 与 `board_dirty_api.log` 记录的是同一脚本、同一镜像，已删除前者。
> 2026-10-25：同一镜像再做了一次真实断电上电，完整启动文本见 `board_coldboot_20261025.raw.log`（fogccclinux，U-Boot → Linux → `login:`）；`board_coldboot_20261024.raw.log` 是同镜像更早那次上电（落在 archlinux）的记录，`board_coldboot_reboot_20261024.raw.log` 是随后切到 fogccclinux 的 reboot 记录。

| 文件 | 命令 | 结论 | 谁引用 |
| --- | --- | --- | --- |
| `board_test_main.log` | `./bin/test_main` | 3/3 `ALL PASS`（Test 1 只比计数；耗时见 `board_three_way.log`）| README §1 结果 |
| `board_gc_test.log` | `sh run_gc.sh 4096 8 2` | `PASSED (all invariants): 8/8` | README 可靠性 |
| `board_run_gc.log` | `tools/debug/run_board_suite.ps1` → `sh run_gc.sh 4096 8 2` | `PASSED (all invariants): 8/8` | README 可靠性 |
| `board_abort_test.log` | `python3 -u tests/abort_test.py` | T1–T5 `RESULT: PASS` | README abort 契约 |
| `board_abort_sweep.log` | `python3 -u tests/abort_sweep.py` | `RESULT: PASS (11/11)`（各相位 `bitmap_bad=0`）| README abort 相位 |
| `board_done_race.log` | `python3 -u tests/done_race_test.py` | `RESULT: PASS`（P3 20/20；P1/P2 0/300）| AGENTS #9 / #18 |
| `board_irq.log` | `cd <datadir> && sh tests/irq_drv_test.sh`（**必须是重启后第一条命令**：`done` 必须为 0）| `IRQ_DRIVEN_DONE_OK (before='0 1 44' after='1 0 44')` | README 中断 / AGENTS #20 |
| `board_repeat.log` | `sh run_repeat.sh 10` | 三组重复测量（不同种子 vs Python BFS / 不同图 vs C / 同种子 5 次）⇒ `REPEAT_DONE` | docs 板上速查 |
| `board_freelist_n4096.log` | `python3 -u tests/freelist_n4096_test.py` | 4096 边界全空闲 ⇒ `FREELIST4096_RESULT OK` | docs 阶段 2 / 工具测试索引 |
| `board_phase2_regression.log` / `board_phase2_regression.raw.log` | `tools/serial_phase2.ps1` | side-table 正/负控 + `gc_test 4096 8 2` ⇒ `RESULT: PHASE2_PASS` | docs 阶段 2 |
| `board_phase3_test_main.log` | `tools/debug/run_phase3_board.ps1` 第 1 步 | 3/3 `ALL PASS` | docs 阶段 3 |
| `board_phase3_dirty_set.log` | 同上 第 4 步 `tests/dirty_set_test.py` | `DIRTY_SET_RESULT OK` | docs 阶段 3A |
| `board_phase3_dirty_set_base_neg_20261023.log` | 同上脚本的**修复前**版本，重启后第一个跑（`0x04` 仍是复位值 0）| 引擎按地址 0 读对象头 ⇒ 不追引用（`A marked=2`、`D e1=1`）⇒ `DIRTY_SET_RESULT FAIL` | AGENTS #19（对象基址泄漏负控）|
| `board_phase3_dirty_set_boot_neg_20261023.log` | `tests/dirty_set_test.py` 作**重启后第一个**测试 | `A occ=3 pushed=3` 但 `marked=2`（id 0 的记录没进位图）⇒ `DIRTY_SET_RESULT FAIL`；暖机后同一脚本 `occ=4 marked=6` ⇒ 「AW/W 乱配 ⇒ 伪造/丢失 `DIRTY_PUSH`」的复现件 | AGENTS #20（**开放**）|
| `board_phase3_dirty_concurrent_plain_neg.log` | 同上加 `--plain-push`（旧的不带回执推送）| **负控**：冷窗口那条记录丢失后表现为推送计数偏短或 `marked != oracle`，与带回执的正证形成对照 | AGENTS #20（并发路径 A/B）|
| `board_dirty_concurrent_plain.log` | `dirty_concurrent_test.py --plain-push`（暖机）| `DIRTY_CONCURRENT_RESULT OK`；暖机期不丢，冷窗口的确定性 A/B 见 `board_regs_aww` 两行 | AGENTS #20 |
| `board_phase3_dirty_concurrent.log` | 同上 第 5 步（mutator 走 id 级回执）| `DIRTY_CONCURRENT_RESULT OK`；`ack: retries=0 giveups=0`（本轮没有触发重试）；`live_pushes` 30–31/100 | docs 阶段 3B / AGENTS #20 |
| `board_phase3_dirty_overflow.log` | 同上 第 6 步 | `DIRTY_OVERFLOW_RESULT OK` | docs 溢出契约 |
| `board_phase3_ctrl_spill.log` | 同上 第 7 步 `tests/ctrl_spill_test.py` | `CTRL_SPILL_RESULT OK` | docs 写路径防护 |
| `board_phase3_freelist_contract.log` | 同上 第 3 步 | `CONTRACT_RESULT OK` | docs 阶段 2 契约 |
| `board_phase3_leftover.log` | `tests/dirty_leftover_test.py` | 旧二进制 `q_tail=10 != marked=9` FAIL → 修好后 `ALL PASS` | docs flush 契约 |
| `board_dirty_state_end.log` | `dirty_state.py` + `dirty_leftover_test.py`（链末）| `DIRTY_STATE occ=0`；留两条记录后 `test_main` 仍 `ALL PASS` ⇒ `DIRTY_LEFTOVER_RESULT OK` | AGENTS #18(a) |
| `board_coldboot_verify_20261024.log` | `tools/debug/serial_coldboot_verify.ps1`（上电后立即）| `D1..D6=0`；卡上 `BOOT.BIN` sha256 `ac8d31cc…`；`fpga_manager=operating`；`test_main` 3/3 `ALL PASS` | README 冷启动 / AGENTS #22 |
| `board_coldboot_20261024.raw.log` | 这次上电的整段串口（只读探活；上电落在 archlinux）| U-Boot 2026.01 → Linux → `login:`；启动窗口内未写入任何字节 | README 冷启动 / AGENTS #22 |
| `board_coldboot_reboot_20261024.raw.log` | 切到 fogccclinux 后的 reboot 整段串口 | PetaLinux 启动 → `linux login:`；之后全部板级日志都在这个环境里跑 | README 冷启动 / AGENTS #22 |
| `board_coldboot_20261025.raw.log` | 同一镜像的真实断电上电，整段串口（只读）| U-Boot 2026.01 → Linux 6.18.10 → `PetaLinux 2026.1` → `login:`；上电后卡上 `BOOT.BIN` sha256 仍为 `ac8d31cc…` | README 冷启动 / AGENTS #22 |
| `tag_leak_probe_20261022.log` | `DIRTY_PUSH` 标签规则探针 | 重投递计数不精确、语义安全 | docs / AGENTS #18 豁免 |
| `host_reproduce.log` | `tools/reproduce_all.ps1`（板外）| manifest 一致 + PS 单测 + 六组 xsim（`tb_gc_top` / `tb_axi_read` / `tb_runstart_race` / `tb_cmdfifo_flush` / `tb_regs_aww` / 三个 hand-over TB）全 `PASS` | docs 仿真回归 |
| `xsim_spill_ungated_20261022.log` / `xsim_spill_gated_20261022.log` | `sim\run_sim.bat` | T-CTRL-SPILL：未门控 3 errors → 门控 `PASS` | AGENTS #19 负控 |
| `xsim_dirtyflush_ungated_20261023.log` | `sim\run_sim.bat` | T-DIRTY-FLUSHSPILL：**无任何防护**的 RTL → `drained=0`/`marked=0`（2 errors）| AGENTS #19 负控 1 |
| `xsim_dirtyflushidle_ungated_20261023.log` | `sim\run_sim.bat` | 旧"仅空闲门控"RTL → **T-DIRTY-FLUSHIDLE 失败**（空闲裸 flush 清掉已推记录）| AGENTS #19 负控 2（P2-a 缺口）|
| `xsim_dirtyflushidle_armconsume_20261023.log` | `sim\run_sim.bat` | arm-and-consume RTL → FLUSHIDLE/FLUSHSPILL/QFULL/QFULLNEG/RACE **全过** | AGENTS #19（arm-and-consume）|
| `xsim_qfull_dirty_20261023.log` | `sim\run_sim.bat` | T-DIRTY-QFULL **观测**（峰值占用 4094/4096、`q_full`&&dirty 0 拍、`S_DIRTY_PUSH` 等待 0 拍）+ 强制负控 T-DIRTY-QFULLNEG（`force q_full` + 待处理记录 ⇒ 引擎按分析挂住）⇒「不可达」有了两段证据 | AGENTS #19（q_full+dirty）|
| `board_three_way.log` | `tests/three_way.py`（同一张图）| FPGA / C 未缓存 / C 缓存 / Python，四个计数一致 ⇒ `THREE_WAY_RESULT OK` | README §1 / docs/measurement |
| `board_regs_aww_cost.log` | 同脚本 `--cost`（200 次推送 ×2）| plain **16.1 µs/push** vs acked **30.5 µs/push**（**1.90×**，暖机期 `retries=0`）| AGENTS #20（回执开销）|
| `xsim_handover_neg_20261024.log` | `tools/debug/neg_handover.ps1`（把 `gc_top.v`/`gc_axi_read.v` 换回修复前）| **负控**：三个 TB 全部 `[FAIL]` —— `stale data survived abort: d0=0x22222222` / `stale beat visible: 0xccccdddd`(×2) / `timeout after duplicate START; state=14 q=26` | AGENTS #21 |
| `board_regs_aww_acked.log` | `regs_aww_board_test.py --acked`，重启后第一个跑 | 冷轮 `loss=[]`（回执重试把本会丢的那条补回来）⇒ 暖轮 `loss 0/14` ⇒ `REGS_AWW_RESULT OK` | AGENTS #20 |
| `board_regs_aww.log` | 同一脚本 `--plain`，重启后第一个跑（A/B 对照）| 冷轮 `loss=[8]`（同一镜像、同一时序，plain 丢一条）；暖轮 `loss 0/14` ⇒ `REGS_AWW_RESULT OK` | AGENTS #20 |
| `board_regs_aww_verify_effect.log` | 同脚本 `--verify-effect`，重启后第一个跑 | 冷轮（round 0）**检测到漏**并退回全标记恢复；暖轮 14/14 无需回退 ⇒ `VERIFY_EFFECT_RESULT OK` | AGENTS #20（F1 按效果验收）|
| `board_regs_aww_verified.log` | 同脚本 `--verified`（标签回查 + 重试），重启后第一个跑 | `retries=0 giveups=0` 却仍 `loss=[8]`（3 次启动 3 次）⇒ **标签回查不足以证明 id 落地**（伪造记录可复用同一个 4 位 tag）；暖轮仍 `loss 0/14` | AGENTS #20（A 侧负结果）|
| `board_regs_aww_probe_forge_20261023.log` | 同上脚本的早期版本 | 每轮都多标 id 0（其 WDATA=0 来自位图探测写）⇒ 暖机期也会发生 AW/W 错配，方向是**多标**（安全）| AGENTS #20（暖机侧证据）|
| `xsim_regs_aww_20261024.log` | `sim\run_regs_aww_tb.bat` | `gc_regs` 的 AW/W 契约：配对写正确 / 重复投递只算一次 / 无 AW 时不消费 W（P1–P3）+ P4 INFO（外来 WDATA 成伪造记录）+ P5/P6（回执暴露伪造）⇒ `PASS` | AGENTS #20 |
| `xsim_freelist_20261022.log` | 已退役的独立 `tb_freelist` 台架 | 273 errors（台架期望过期，非 RTL 缺口）；台架源与 runner 已移除 | 退役说明 |

> **口径**：2026-10-22 起不再保留解释器口径的日志（AGENTS #10）。本目录只有
> 「FPGA 引擎 / 同图 C（未缓存·缓存）/ Python 脚本」三口径。
> 旧镜像（`81640C7C` / `3590FBB5` / v4.1）的板级输出随其发布记录退役，需要时可从 git 历史取回。

命名约定：

- `board_<suite>.log` —— 板级套件的**固定名**（重跑覆盖；运行时间写在文件头或首行）
- `board_coldboot_<…>.raw.log` —— 上电启动的整段串口记录
- `xsim_<…>.log` —— `sim\run_sim.bat` 的输出
- 其它（`hw_program.log`、`serial.log`、`*_verify_*.log` …）都是过程日志，默认被 `.gitignore` 忽略，用完即删

串口日志保留原始行宽与换行；导出工具的 ANSI 控制符、提示符回显、`mount` 前导行会被剔除，并在文件头注明，数据行不改。

新增证据日志时要同时做三件事：起一个**固定名**、在 `.gitignore` 里加白名单、并在引用它的文档里写清
**命令 + commit + 日期**（AGENTS.md §4.8.1）。
