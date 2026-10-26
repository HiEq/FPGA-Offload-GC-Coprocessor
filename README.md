# FPGA Offload GC Coprocessor（FOGC²）

[![Platform](https://img.shields.io/badge/Platform-Xilinx%20Zynq--7000%20XC7Z100-blue)](#1-结果)
[![RTL](https://img.shields.io/badge/RTL-Verilog%202001-green)](#3-设计与接口)
[![Vivado](https://img.shields.io/badge/Vivado-2026.1-orange)](docs/build.md)
[![License](https://img.shields.io/badge/License-MIT-yellow)](#7-license)
[![CI](https://github.com/HiEq/FPGA-Offload-GC-Coprocessor/actions/workflows/lint.yml/badge.svg)](https://github.com/HiEq/FPGA-Offload-GC-Coprocessor/actions/workflows/lint.yml)

面向托管堆的 FPGA GC 协处理器（Zynq-7000 原型）：对象体留在 DDR，引用关系抽成连续 side table
（每对象一个 u32 数组，`0xFFFFFFFF` 结尾）；PL 负责标记与空闲扫描，分配、引用更新与回收策略
由 PS 侧软件负责——本仓库提供寄存器与驱动接口，未接入语言运行时。stop-the-world，
上限 4096 对象 / 1 MB 图区，测量范围仅标记与空闲扫描。

> 当前证据：位流 `6D479244…` / `BOOT.BIN` `26fb8621…`，2026-10-25 冷启动复验。
> 原始日志在 `tools/logs/`（索引 [`tools/logs/README.md`](tools/logs/README.md)）；
> 测量口径与证据边界见 [`docs/measurement.md`](docs/measurement.md)。
> CI 只做静态检查与定向仿真，**不做** Vivado 综合/实现、xsim、PetaLinux 或上板。

Contents: [结果](#1-结果) · [快速开始](#2-快速开始) · [设计与接口](#3-设计与接口) ·
[证据](#4-证据) · [发布](#5-发布) · [目录与调试](#6-目录与调试) · [License](#7-license)

详细文档：[上板/串口](docs/board-usage.md) · [构建与平台](docs/build.md) ·
[测量口径](docs/measurement.md) · [仿真矩阵](docs/simulation.md) ·
[设计细节](docs/design-details.md) · [全部文档](docs/README.md)

## 1. 结果

| 对比对象 | 口径 | 每对象 | 加速 |
|---|---|---|---|
| **FPGA 标记**（`three_way.py`）| 同图 4000 对象 | **172 ns** | — |
| C，逐条读 DDR（未缓存）| 同图同 BFS | 577 ns | **3.4×** |
| C，数据驻留 cache | heap 副本 | 196 ns | **1.1×** |
| Python 脚本 BFS（逐条读 `/dev/mem`）| 同图 | 45.9 µs | **267×** |

> `FPGA` 列只含引擎时间（`CYCLES / 100 MHz`），不含构图与驱动开销。
> 四行来自同一张图（`tests/three_way.py`），出处 `tools/logs/board_three_way.log`；
> 逐项口径见 [`docs/measurement.md`](docs/measurement.md)。`test_main` 只查计数正确性。

**实现范围**：stop-the-world，写 `START`、轮询 `DONE`。对象图由 `csrc/fpga_gc.c` /
`python/fogccc.py` 按「对象头 + 引用数组」布局构造；**未接入**任何语言运行时的 `gc` 模块。

## 2. 快速开始

```powershell
# 位流（PC）
vivado -mode batch -source vivado/build.tcl
```

```bash
# 板上二进制（PC，PetaLinux SDK）
SDK_ENV=<sdk> ./csrc/build_c_bins.sh      # test_main / libfogccc.so
```

卡布局、烧录与上电步骤见 [`docs/board-usage.md`](docs/board-usage.md)；平台规格、工具链版本、
资源与时序见 [`docs/build.md`](docs/build.md)。

板上自检：

```sh
cd /run/media/USERDATA-mmcblk0p2
./bin/test_main                 # 3 项（FPGA vs C 计数）
sh run_gc.sh 4096 8 2           # 8 轮随机图，判据 PASSED (all invariants): 8/8
python3 tests/three_way.py      # 同一张图：FPGA / C 未缓存 / C 缓存 / Python
```

宿主回归：

```bash
python -m unittest discover -s tests -p "test_*.py"   # 仓库契约
```

```powershell
powershell -File tools/reproduce_all.ps1             # 六组 xsim + 清单 + PS 单测
```

## 3. 设计与接口

### 寄存器映射

| 偏移 | 名称 | R/W | 说明 |
|------|------|-----|------|
| 0x00 | CTRL | R/W | [0] start · [1] 保留 · [2] clear_q · [3] abort · [4] bm_keep（与 [0] 同一次写）· [5] dirty_flush（武装式）· [31] done；**写时 `WDATA[31:20]` 必须为 `0xA50`** |
| 0x04 | OBJ_BASE | R/W | 对象图 DDR 物理地址 |
| 0x08 | OBJ_COUNT | R/W | 对象总数 |
| 0x0C | ROOT_COUNT | R/W | 根集数量（≤256）|
| 0x10 | MARKED | R | 标记对象数 |
| 0x14 | CYCLES | R | 硬件周期计数 |
| 0x18 | Q_HEAD | R | 队列头指针 |
| 0x1C | Q_TAIL | R | 队列尾指针 |
| 0x20 | STATUS | R | [0] 队列溢出 · [1] AXI 读错误 · [2] 引用失步 · [3] 坏对象头 · [4] 引擎 idle · [5] free-list 扫描 busy |
| 0x24 | BM_ADDR | R/W | 位图探针地址（0–4095，引擎空闲时有效） |
| 0x28 | BM_DATA | R | 位图探测数据（2 拍延迟；读后勿改 `BM_ADDR`）|
| 0x30 | MAGIC | R | 固定 `0x47434343`（"GCCC"）|
| 0x34 | VERSION | R | 固定 `0x0004_0301`（v4.5 起）|
| 0x38 | FREE_COUNT | R | 未标记对象数（mark 完成后扫描，扫描期 `STATUS[5]=1`）|
| 0x3C | FREE_DATA | R | 读一次弹出一个 free 对象 ID |
| 0x40+ | ROOT_LIST | R/W | 根集 ID 数组（`0x40`–`0x43F`，最多 256 个）；读回用于写后校验 |
| 0x440 | DIRTY_PUSH | W/R | **W** `0xA5400000 \| (tag<<12) \| id`（标记符 = `WDATA[31:20]`），tag 每次推送必须变化；**R** 当前 FIFO 占用 |
| 0x444 | DIRTY_STAT | R | [8:0] 占用 · [9] 溢出（粘滞）· [10] 待处理 · [19:16] 最后接受的 tag · [31:20] 最后接受的 id |
| 0x448 | DIRTY_DRAINED | R | 本 epoch 已消费条数（每次 start 清零）|
| 0x44C | DIRTY_PUSHED | R | 自上次 flush 以来接受的条数 |
| 0x450 | DIRTY_POPPED | R | 自上次 flush 以来 pop 的条数 |

`CTRL[5]` 与 `DIRTY_*` 的契约见 [`docs/design-details.md`](docs/design-details.md)；
`DIRTY_PUSH` 用 `0x440`（根表止于 `0x43F`）。

### 关键参数

| 参数 | 值 | 说明 |
| --- | --- | --- |
| `MAXO` | **8** | 未完成读上限，等于 PS7 `S_AXI_HP0` 的 `NUM_READ_OUTSTANDING` |
| `QD` | **80** | 每条流的命令/数据 FIFO 容量 |
| `PD` | **4** | 对象头暂存环深度 = 预取深度 |
| `DQD` | **8** | 引用描述符队列深度 |
| 对象上限 | **4096** | 12 位 ID / 位图 4096×32 / 队列 4096 深 |
| AXI 协议 | **AXI3** | HP 口原生：`ID_WIDTH=6`、单拍、`ARSIZE=3` |
| 流 ID | **0 = 引用, 1 = 对象头** | 同 ID 保序，异 ID 互不阻塞 |
| 时钟 | **FCLK0 = 100MHz** | 单时钟域，无 CDC |
| 位图 / 队列 | 4096×32 / 4096×12 | 128 Kb / 48 Kb |

### 对象图格式

```
@ obj_base + k*16:                @ ref_addr:
┌──────────────────────┐          ┌──────────────────────────┐
│ +0:  uint32 obj_id   │          │ [ref0][ref1]...[0xFFFF]  │
│ +4:  uint32 ref_count│          │                          │
│ +8:  uint32 ref_addr │──────────┘                          │
│ +12: uint32 reserved │          └──────────────────────────┘
└──────────────────────┘
```

引擎读对象头取 `ref_count` 与 `ref_addr`，再按 `ref_addr + j*4` 读第 j 个引用。

### 脏边与增量标记

`gc_dirty_fifo` 是标记引擎的第二工作源：写 `0x440` 推入一个 ID，未标则置位并计数，
已标则强制重扫（不计数），`S_DONE` 额外要求 FIFO 为空。满 256 丢弃并置溢出位，
软件见溢出退回全标记。epoch 为「全标记 → 增量（mutator 可并发推送）→ remark 收口」。
协议、屏障顺序、回执与并发证据见 [`docs/design-details.md`](docs/design-details.md)。

## 4. 证据

| 套件 | 结果 |
|---|---|
| 冷启动 `D1..D6` / `test_main` | 0 / 3/3（同一次上电的日志；卡上当前二进制）|
| 阶段 2 / 阶段 3 | `PHASE2_PASS`、`CONTRACT_RESULT OK`、dirty 全套 OK、收尾 `occ=0` |
| `run_gc.sh 4096 8 2` | 8/8 |
| `abort_test` / `abort_sweep` / `done_race` | T1–T5 / 11/11 / P3 0/20 |
| `three_way.py`（同图四方）| `THREE_WAY_RESULT OK` |
| `tb_flush_data` / `tb_stale_ar_flush` / `tb_start_while_busy` | PASS（负控对修复前 RTL 全部 FAIL）|

日志索引与逐条出处：[`tools/logs/README.md`](tools/logs/README.md)。
仿真用例矩阵：[`docs/simulation.md`](docs/simulation.md)。

## 5. 发布

当前发布：v4.9（GitHub Latest）。v4.8 保留为正式版；v4.2–v4.7 为 prerelease 历史快照；v4.1 仍是正式版，但不再是最新。
v4.9 只改 FOGCCC 的登录体验：登录时探测终端尺寸、状态栏显示实时 CPU%；位流与 `VERSION=0x0004_0301` 不变。

`BOOT.BIN` 与 `image.ub` 不入库，随 GitHub Release 发布（再分发限制见 [`NOTICE`](NOTICE)）。

| 资产 | 烧录位置 | 大小 | SHA256 |
| --- | --- | --- | --- |
| `BOOT.BIN` | BOOT 分区根目录 | 18,582,724 B | `d20530bc3ddbfd01be9cacaeac30618d568b5ec6c180232dab64cf905a3898fd` |
| `image.ub` | BOOT 分区根目录 | 47,041,467 B | `f9089048088781c94706f3c65fb6e077aa2cb82a26711de3574323227bd3cb02` |
| `card-boot.zip` | 解压到 BOOT 根目录 | 5,176 B | `6844e8612cafca02cee44696ca6948ee345e1a2d2d11e7aaf77eac6a99764e6a` |
| `card-userdata.zip` | 解压到 USERDATA 根目录 | 94,305 B | `7a5ba950097bf0b4c87ff73819c647f3913dbb755a7c8f0685c9286426002f9c` |

校验：四个二进制资产与 `SHA256SUMS.release` 置于同一目录，执行 `sha256sum -c SHA256SUMS.release`。
每个版本的变更内容、验证结果与已知限制见 [`docs/releases.md`](docs/releases.md)。
卡布局、烧录与上电步骤见 [`docs/board-usage.md`](docs/board-usage.md)。
`card-userdata.zip` 的 `ko/fogccc-irq.ko` 与发布镜像的内核严格配对
（`vermagic=6.18.10-xilinx-g4f7afe14f724`）。

## 6. 目录与调试

```
rtl/       顶层 + 寄存器 + BFS 引擎 + 位图/队列/free-list/脏 FIFO + AXI 读
sim/       自检 testbench、定向 TB、AXI 协议检查器
csrc/      驱动、test_main、Python BFS 参照
python/    ctypes 绑定
vivado/    BD + 综合/实现脚本
tools/     串口与上板脚本、测试、日志
artifacts/ 卡上产物与二进制清单（BOOT.BIN/image.ub 不入库）
docs/      构建、上板、测量、仿真、设计细节
```

完整目录说明见 [`docs/build.md`](docs/build.md)。调试：标记结果/周期/队列在 `0x10`/`0x14`/`0x18`/`0x1C`，
对象图在 DDR `0x1E000000`；内部信号可用 ILA（`vivado/build.tcl` 加 `system_ila`）。

## 7. License

MIT（见 `LICENSE`）。例外与第三方组件见 [`NOTICE`](NOTICE)。
