# 发布记录：变更内容、验证结果与已知限制

Release 页面仅保留本页链接与资产哈希表；逐版本的变更内容、验证结果与已知限制见下文。
本页在 dev-hieq（开发线，含逐提交历史与证据）与 main（发布分支）上都可读；main 只承载最近一次同步的 tag 树，每次同步一个 squash 提交。
证据日志位于 [`tools/logs/`](../tools/logs/README.md)，每份文件头记录命令、位流、BOOT 哈希、提交与日期。

| 版本 | 日期 | 摘要 | tag |
|---|---|---|---|
| v4.9 | 2026-10-26 | 登录探测终端尺寸、状态栏显示实时 CPU% | `5c70714` |
| v4.8 | 2026-10-26 | CPU 800 MHz、控制台 921600、FOGCCC initramfs 内置 `lf` | `e0be9bb` |
| v4.7 | 2026-10-25 | `barrier_verify()` 把探针哨兵当作未验证（仅 USERDATA） | `78a431a` |
| v4.6 | 2026-10-25 | 位图探针地址写后校验（仅 USERDATA） | `933d04bc` |
| v4.5 | 2026-10-25 | 数据寄存器写后校验（根集可读回） | `a02f7ada` |
| v4.4 | 2026-10-25 | 命令写携带目的地址标记 | `3a902b20` |
| v4.3 | 2026-10-24 | cmdfifo 同拍 enqueue 门控进入镜像 | `23c7cc8b` |
| v4.2 | 2026-10-24 | 硬件 GC 标记（Phase 3A/3B） | `cc2f02b` |
| v4.1 | 2026-10-20 | PL flush 修复（`run_start`/`abort` + 命令 FIFO） | `f9a6b5b` |

tag 列记录该版本的发布提交；tag 指针可能比它晚一个仅含文档与日志的提交，权威值以 `git rev-parse <tag>` 为准。

GitHub Latest 指向 v4.9（800 MHz）。v4.7（667 MHz）保留为正式版；v4.1–v4.6 与 v4.8 标为 Pre-release 历史快照，仍可下载，但不作为推荐版本。正式版只有两个：v4.7 与 v4.9。

---

## v4.9

**变更内容**

- 登录阶段不再出现尺寸应答乱码：新增 `/usr/local/bin/tty-size`（发 `ESC[18t`，等 1.5 秒，读到结尾的 `t` 再排空 0.2 秒，然后恢复 echo）和 `/etc/profile.d/00-tty-size.sh`（在 `99-byobu.sh` 之前执行，并把 `FIRSTTIMESETUP` 清 0，让 Yocto 自带的 `resize` 不执行）。此前那段 `resize` 等不及应答就放弃，晚到的 `ESC[8;行;列t` 被当成命令送进 shell，登录时出现 `sh: [8: command not found`。
- 状态栏的 `load_average` 改成实时 CPU 占用：`/usr/lib/byobu/load_average` 定义 `__load_average()`，用两次 `/proc/stat` 采样算 `(总-空闲-等待)/总`，显示形如 `21%`；上一次的累计值存在 `/run/byobu_cpu.prev`。原来的 loadavg 会被阻塞在 D 状态的 tmux（往没人读的串口写状态栏）抬到 1 以上，看起来像 CPU 很忙。
- 同一份 `load_average` 也写入了 Arch 根分区（p3）；Arch 不在本仓库的发布范围内。
- `BOOT.BIN`、位流、`system.dtb`、`card-userdata.zip` 与 v4.8 相同；`card-boot.zip` 重新打包（文件未变，哈希变化）。

**验证结果**

- 真实断电上电（921600）：整段启动到 `linux login:` 里 `ESC[8;r;ct` 出现 0 次，`sh: [8:` 0 次（`tools/logs/board_coldboot_20261026_v49.raw.log`）。
- 登录后：`stty -F /dev/ttyPS0 size` 等于终端应答（本次 35x120）；`byobu-status tmux_right` 里 `command not found` 0 次，数值形如 `21%%`；`/usr/local/bin/tty-size` 与 profile 脚本都在；`lf -version` 为 `r42`（`tools/logs/board_v49_verify.log`）。
- 同一次构建的 `image.ub` `f9089048…`；`card-userdata.zip` 仍为 `7a5ba950…`。

**已知限制**

- 串口没有窗口尺寸变化通知：改窗口大小后需要重新登录一次才会重新探测。
- 没人读串口时 tmux 仍会阻塞在 D 状态、loadavg 仍会升高；状态栏现在显示 CPU%%，不再受它影响（btop 显示的一直是 CPU%%）。
- 800 MHz 仍是 XC7Z100-2 的额定上限，没有余量。

---

## v4.8

**变更内容**

- `BOOT.BIN`：FSBL 的 `ps7_init` 把 `ARM_PLL_CTRL(0xF8000100)[18:12]` 从 40（33.333 MHz x 40 / 2 = 666.67 MHz）改为 48（800 MHz），并把 U-Boot 默认环境的 `baudrate` 从 115200 改为 921600。位流未变（`VERSION=0x0004_0301`），与原镜像逐字节比较只有 10 字节不同。
- `image.ub`：用 `petalinux/` 重建。`CONFIG_SUBSYSTEM_SERIAL_PS7_UART_0_BAUDRATE_921600=y`、`CONFIG_SUBSYSTEM_USER_CMDLINE="console=ttyPS0,921600 earlycon"`。Petalinux 的这个选项只喂 U-Boot 与设备树，不驱动 `sysvinit-inittab` 生成的 `/etc/inittab`，所以另加 `ROOTFS_POSTPROCESS_COMMAND` 把 `start_getty 115200 ttyPS0` 改成 921600——不改这一行，getty 启动时会把 tty 改回 115200。
- FOGCCC 是 initramfs，根文件系统不可持久化：`lf` r42（静态 arm EABI5，5,570,744 B）和 root 家目录下的 `.config/lf/lfrc` 由 `project-spec/meta-user/recipes-core/images/files/` 加 image bbappend 打进 initramfs。
- `artifacts/boot.scr` 换成只启动 FOGCCC 的脚本（`console=ttyPS0,921600`，源文本 `artifacts/boot-fogccc.cmd`）；`uEnv.txt` 同步 921600。`card-userdata.zip` 与 v4.7 逐字节相同。
- `tools/serial-monitor.ps1` / `tools/watch-serial.bat` 默认波特率改为 921600。

**验证结果**

- 真实断电上电（不是 reboot）：串口 921600 下完整记录 U-Boot 2026.01 -> Linux 6.18.10 -> PetaLinux 2026.1 -> `linux login:`（`tools/logs/board_coldboot_20261026_v48.raw.log`）。
- `sched_clock: 64 bits at 200MHz`、`BogoMIPS 399.99`、`SMP: Total of 2 processors activated (799.99 BogoMIPS)`，即 CPU 800 MHz。
- `/proc/cmdline` = `console=ttyPS0,921600 earlycon`；`/usr/bin/lf` 5,570,744 B、`lf -version` 输出 `r42`、`lf /etc` 能进入并 `q` 退出（`tools/logs/board_v48_verify.log`）。
- `card-userdata.zip` 重打后 SHA256 仍是 `7a5ba950…`；`card-boot.zip` 为 `89abacd2…`（旧 5,951 B -> 5,176 B，boot.scr 换成 384 B 的 FOGCCC 脚本、uEnv.txt 改 921600）。
- 同一份 `BOOT.BIN` 在 Arch 侧也冷启动过（13.02 s 到 multi-user、串口输入溢出 0 次）；Arch 镜像不在本仓库发布范围内。

**已知限制**

- 800 MHz 是 XC7Z100-2 的额定上限（DS190：Z-7100 -2 为 800 MHz），没有余量；长时间满载需关注散热。
- FSBL 早于 U-Boot 的输出仍在 115200（厂商预编译的 FSBL，未改），921600 下开机最前面约 0.5 秒是乱码。
- `image.ub` 非位级可复现（gzip 时间戳），以功能验证为准。
- `card-boot.zip` 里的 `system.dtb` 保留但启动脚本不加载（设备树在 `image.ub` 内）。
- 内置 `lfrc` 是最小配置（`hidden` / `drawbox` / `scrolloff` / `period`），不含个人配置。
- `use-fogccc` 标记在 p1；删除后卡上不再有可启动的系统（本仓库只发布 FOGCCC）。

---

## v4.7

**变更内容**

- `python/fogccc.py`：`barrier_verify()` 由 `all(read_mark(i) ...)` 改为 `read_mark(i) == 1`。v4.6 的探针在同一对象上可能返回 `0xFFFFFFFF`（引擎不空闲、等待超时、探针地址写未生效），旧判断把该哨兵当成真值，探针失败反而报告“全部已标记”，`barrier_verify()` 因此永远不会触发全标记回退。
- 新增 `tests/test_fogccc_binding.py`（宿主单测，stub `ctypes.CDLL` + 假 `read_mark`）与 `tools/tests/barrier_verify_test.py`（板级：已标记 → `True`，未标记与混合集合 → `False`）。
- `tools/make_card.ps1` 把 `regs_aww_board_test.py` 与 `barrier_verify_test.py` 一并放进卡上目录；`tools/make_release_zips.ps1` 在重打 zip 后自行刷新 `SHA256SUMS.release`，避免 zip 与清单脱节。
- 仅 USERDATA 侧变化；`BOOT.BIN`、位流与 `VERSION=0x00040301` 未变。

**验证结果**

- 宿主单测 6/6 `OK`；负控：对修复前的模块（`FOGCCC_PATH` 指向 `git show v4.6:python/fogccc.py`）同一套用例 2/6 失败（哨兵用例与“全哨兵”用例）。
- 板级 `barrier_verify_test.py`：`BARRIER_VERIFY_RESULT OK`（`marked 16 -> True`、`unmarked id 3 -> False`、`mixed -> False`）。
- 板上哨兵对照（同一张卡上同时加载修复前/后的 `fogccc.py`，`read_mark` 固定返回 `0xFFFFFFFF`）：修复前 `True`，修复后 `False`。
- 哨兵来源由 `csrc/test_read_mark_host.c` 直接验证：用数组冒充寄存器块，`STATUS` 不带 `IDLE` 时真实的 `fpga_gc_read_mark()` 返回 `0xFFFFFFFF` 且不写 `BM_ADDR`；空闲时按位返回 `0/1`。负控（把两处 `return 0xFFFFFFFF` 改成 0）同一用例 `FAIL`。该步已加入 `gate` 工作流。
- 回归：`test_main` 3/3 `ALL PASS`、`dirty_api_test.py` `DIRTY_API_RESULT OK`、`regs_aww --verify-effect` `VERIFY_EFFECT_RESULT OK`（0/14 需回退）。

**已知限制**

- `barrier_verify()` 仍是“必要但不充分”：epoch 之前就已标记的目标无法证明该容器被重扫，调用方应按本轮新可达的目标检查，或用全量计数/判据兜底。
- 哨兵路径在板上没有确定性触发方式（需要引擎不空闲或探针地址写不生效）：板级用“固定返回哨兵的假 `read_mark`”构造 Python 决策这一侧；哨兵本身由 `csrc/test_read_mark_host.c` 用真实驱动代码覆盖（`gate` 工作流执行）。

---

## v4.6

**变更内容**

- `csrc/fpga_gc.c`：`fpga_gc_read_mark()` 的探针地址写改为经 `reg_wr_verified()`（写入 → 回读 → 重试），失败返回 `0xFFFFFFFF`。`barrier_verify()` 依赖该探针，此前一次 AW/W 错配就可能探测到错误对象，从而漏判“未重扫”。
- 仅重新编译 USERDATA 侧二进制；`BOOT.BIN`、位流与 `VERSION=0x0004_0301` 均未变化。

**验证结果**

- 断电上电（整机断电，非 reboot）：串口完整记录 U-Boot → Linux 6.18.10 → `login:`（`tools/logs/board_coldboot_20261025_v46.raw.log`）。登录后 `D1..D6=0`，卡上 `BOOT.BIN` sha256 `26fb8621…` 与发布资产一致，`PL_GRAPH_NOMAP_OK`、`fpga_manager=operating`、`VERSION=0x00040301`，`test_main` 3/3 `ALL PASS`（`tools/logs/board_coldboot_verify_20261025_v46.log`）。
- 同一次上电后的第一条 `DIRTY_PUSH` 序列：`regs_aww` 冷轮 `loss=[] forged=[]`，暖轮 `loss 0/14`、多标 `0/14`，`REGS_AWW_RESULT OK`（`tools/logs/board_regs_aww_cold_20261025_v46.log`）。
- 同一会话：`dirty_api_test` `DIRTY_API_RESULT OK`（`acked push: [True, True]`）；`regs_aww --verify-effect` `VERIFY_EFFECT_RESULT OK`（0/14 需回退），该路径即 v4.6 改写后的探针写（`tools/logs/board_dirty_api_probe_20261025_v46.log`）。
- 位流与 `BOOT.BIN` 与 v4.5 相同（md5 `6D479244…` / sha256 `26fb8621…`），本次上电同时闭合了“发布 USERDATA + 发布 PL”未共同经历断电上电的缺口。

**已知限制**

- 探针校验失败时返回 `0xFFFFFFFF`：C 侧调用者按“未知”处理，不把它当标记；但 Python 绑定的 `barrier_verify()` 当时用 `all(...)` 判断，把哨兵当成真值，因此不会触发全标记回退——该缺陷由 v4.7 修复。
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

- 时序裕量较小：WNS/WHS 均为 +0.049 ns（根集读通道增加了一条路径），满足约束但接近临界。
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
