# FPGA Offload GC Coprocessor（FOGCCC）

[![Platform](https://img.shields.io/badge/Platform-Xilinx%20Zynq--7000%20XC7Z100-blue)](#1-结果)
[![RTL](https://img.shields.io/badge/RTL-Verilog%202001-green)](#3-设计与接口)
[![Vivado](https://img.shields.io/badge/Vivado-2026.1-orange)](docs/build.md)
[![License](https://img.shields.io/badge/License-MIT-yellow)](#7-license)
[![CI](https://github.com/HiEq/FPGA-Offload-GC-Coprocessor/actions/workflows/lint.yml/badge.svg)](https://github.com/HiEq/FPGA-Offload-GC-Coprocessor/actions/workflows/lint.yml)

面向托管堆的 FPGA GC 协处理器（Zynq-7000 原型）。对象体驻留 DDR，引用关系整理为连续的 side table
（每对象一个 u32 数组，0xFFFFFFFF 结尾）；标记与空闲对象扫描由 PL 完成，分配、引用更新与回收策略
由 PS 侧软件负责。本仓库提供寄存器映射与驱动接口，采用 stop-the-world 方式，对象数上限 4096、
图区上限 1 MiB，当前未接入语言运行时，测量范围限于标记与空闲扫描两个阶段。

当前证据：位流 6D479244…、BOOT.BIN d20530bc…、image.ub c958eac9…（v4.13，2026-10-27）。
原始日志在 tools/logs/（索引 [tools/logs/README.md](tools/logs/README.md)）；
测量条件与证据边界见 [docs/measurement.md](docs/measurement.md)。
CI 只做静态检查与定向仿真，**不做** Vivado 综合/实现、xsim、PetaLinux 或上板。

Contents: [结果](#1-结果) · [快速开始](#2-快速开始) · [设计与接口](#3-设计与接口) ·
[证据](#4-证据) · [发布](#5-发布) · [目录与调试](#6-目录与调试) · [License](#7-license)

详细文档：[上板/串口](docs/board-usage.md) · [构建与平台](docs/build.md) ·
[测量条件](docs/measurement.md) · [仿真矩阵](docs/simulation.md) ·
[设计细节](docs/design-details.md) · [全部文档](docs/README.md)

## 1. 结果

| 对比对象 | 测量条件 | 每对象 | 相对 FPGA |
|---|---|---|---|
| **FPGA 标记**（fpga_vs_c_vs_python.py）| 同一张图，4000 对象 | **171 ns** | — |
| C，逐条读 DDR（未缓存）| 同一张图、同一 BFS | 541 ns | **3.2×** |
| C，数据驻留 cache | 堆上的副本 | 164 ns | **1.0×** |
| Python 脚本 BFS（逐条读 /dev/mem）| 同一张图 | 37.9 µs | **221×** |

FPGA 列只含引擎时间（CYCLES / 100 MHz），不含构图与驱动开销；171 ns 以已标记的 3766 个
对象为分母（645.4 µs / 4000 = 161 ns）。最后一列为相对 FPGA 的时间比，1.0× 表示与 FPGA 相当。
四行来自同一张图（tests/fpga_vs_c_vs_python.py，v4.12 / PS 800 MHz）；逐项测量条件与证据见
[docs/measurement.md](docs/measurement.md)。test_main 只查计数正确性。

**实现范围**：stop-the-world，写 START、轮询 DONE。对象图由 csrc/fpga_gc.c /
python/fogccc.py 按「对象头 + 引用数组」布局构造；**未接入**任何语言运行时的 gc 模块。

## 2. 快速开始

```powershell
# 位流（PC）
vivado -mode batch -source vivado/build.tcl
```

```bash
# 板上二进制（PC，PetaLinux SDK）
SDK_ENV=<sdk> ./csrc/build_c_bins.sh      # test_main / libfogccc.so
```

卡布局、烧录与上电步骤见 [docs/board-usage.md](docs/board-usage.md)；平台规格、工具链版本、
资源与时序见 [docs/build.md](docs/build.md)。

板上自检：

```sh
cd /run/media/USERDATA-mmcblk0p2
sh fpga_vs_c.sh                     # test_main 3 项（FPGA vs C 计数）
sh fpga_vs_python.sh 4096 8 2       # 8 轮随机图，判据 PASSED (all invariants): 8/8
sh fpga_vs_python_repeat.sh 10      # 10 个种子 + 固定种子 5 次，判据 REPEAT_DONE
python3 tests/fpga_vs_c_vs_python.py  # 同一张图：FPGA / C 未缓存 / C 缓存 / Python
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
| 0x00 | CTRL | R/W | [0] start · [1] 保留 · [2] clear_q · [3] abort · [4] bm_keep（与 [0] 同一次写）· [5] dirty_flush（预置，下一次全量标记生效）· [31] done；**写时 WDATA[31:20] 必须为 0xA50** |
| 0x04 | OBJ_BASE | R/W | 对象图 DDR 物理地址 |
| 0x08 | OBJ_COUNT | R/W | 对象总数 |
| 0x0C | ROOT_COUNT | R/W | 根集数量（≤256）|
| 0x10 | MARKED | R | 标记对象数 |
| 0x14 | CYCLES | R | 硬件周期计数 |
| 0x18 | Q_HEAD | R | 队列头指针 |
| 0x1C | Q_TAIL | R | 队列尾指针 |
| 0x20 | STATUS | R | [0] 队列溢出 · [1] AXI 读错误 · [2] 引用失步 · [3] 坏对象头 · [4] 引擎 idle · [5] free-list 扫描 busy |
| 0x24 | BM_ADDR | R/W | 位图探针地址（0–4095，引擎空闲时有效） |
| 0x28 | BM_DATA | R | 位图探测数据（2 拍延迟；读后勿改 BM_ADDR）|
| 0x30 | MAGIC | R | 固定 0x47434343（"GCCC"）|
| 0x34 | VERSION | R | 固定 0x0004_0301（v4.5 起）|
| 0x38 | FREE_COUNT | R | 未标记对象数（mark 完成后扫描，扫描期 STATUS[5]=1）|
| 0x3C | FREE_DATA | R | 读一次弹出一个 free 对象 ID |
| 0x40+ | ROOT_LIST | R/W | 根集 ID 数组（0x40–0x43F，最多 256 个）；读回用于写后校验 |
| 0x440 | DIRTY_PUSH | W/R | **W** 0xA5400000 \| (tag<<12) \| id（标记符 = WDATA[31:20]），tag 每次推送必须变化；**R** 当前 FIFO 占用 |
| 0x444 | DIRTY_STAT | R | [8:0] 占用 · [9] 溢出（粘滞）· [10] 待处理 · [19:16] 最后接受的 tag · [31:20] 最后接受的 id |
| 0x448 | DIRTY_DRAINED | R | 本 epoch 已消费条数（每次 start 清零）|
| 0x44C | DIRTY_PUSHED | R | 自上次 flush 以来接受的条数 |
| 0x450 | DIRTY_POPPED | R | 自上次 flush 以来 pop 的条数 |

CTRL[5] 与 DIRTY_* 的契约见 [docs/design-details.md](docs/design-details.md)；
DIRTY_PUSH 用 0x440（根表止于 0x43F）。

### 关键参数

| 参数 | 值 | 说明 |
| --- | --- | --- |
| MAXO | **8** | 未完成读上限，等于 PS7 S_AXI_HP0 的 NUM_READ_OUTSTANDING |
| QD | **80** | 每条流的命令/数据 FIFO 容量 |
| PD | **4** | 对象头暂存环深度 = 预取深度 |
| DQD | **8** | 引用描述符队列深度 |
| 对象上限 | **4096** | 12 位 ID / 位图 4096×32 / 队列 4096 深 |
| AXI 协议 | **AXI3** | HP 口原生：ID_WIDTH=6、单拍、ARSIZE=3 |
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

引擎读对象头取 ref_count 与 ref_addr，再按 ref_addr + j*4 读第 j 个引用。

### 脏边与增量标记

gc_dirty_fifo 是标记引擎的第二工作源：写 0x440 推入一个 ID，未标则置位并计数，
已标则强制重扫（不计数），S_DONE 额外要求 FIFO 为空。满 256 丢弃并置溢出位，
软件见溢出退回全标记。epoch 为「全标记 → 增量（mutator 可并发推送）→ remark 收口」。
协议、屏障顺序、回执与并发证据见 [docs/design-details.md](docs/design-details.md)。

## 4. 证据

| 套件 | 结果 |
|---|---|
| 冷启动 D1..D6 / test_main | 0 / 3/3（证据为 v4.5 镜像；卡上当前为 v4.13）|
| 阶段 2 / 阶段 3 | PHASE2_PASS、CONTRACT_RESULT OK、dirty 全套 OK、收尾 occ=0 |
| fpga_vs_python.sh 4096 8 2 | 8/8 |
| abort_test / abort_sweep / done_race | T1–T5 / 11/11 / P3 失配 0/20（20/20 正确）|
| fpga_vs_c_vs_python.py（同一张图的四路对比）| THREE_WAY_RESULT OK |
| tb_flush_data / tb_stale_ar_flush / tb_start_while_busy | PASS（负控对修复前 RTL 全部 FAIL）|

日志索引与逐条出处：[tools/logs/README.md](tools/logs/README.md)。
仿真用例矩阵：[docs/simulation.md](docs/simulation.md)。

## 5. 发布

当前发布 v4.13（GitHub Latest，800 MHz）。v4.7（667 MHz）为上一个正式版；v4.1–v4.6、
v4.8–v4.12 为 Pre-release 历史快照。v4.13 只改文档与测试脚本，镜像与 v4.12 相同。

BOOT.BIN 与 image.ub 不入库，随 Release 发布（再分发限制见 [NOTICE](NOTICE)）。
BOOT.BIN、image.ub 放 BOOT 分区根目录；card-boot.zip 与 card-userdata.zip 分别解压到
BOOT 与 USERDATA 根目录。

| 资产 | 大小 | SHA256 |
| --- | --- | --- |
| BOOT.BIN | 18,582,724 B | d20530bc3ddbfd01be9cacaeac30618d568b5ec6c180232dab64cf905a3898fd |
| image.ub | 47,762,547 B | c958eac9970c3a4ddeb333a98922169801b484c706bbd77cf6bc8cbfd29c329f |
| card-boot.zip | 5,176 B | 6844e8612cafca02cee44696ca6948ee345e1a2d2d11e7aaf77eac6a99764e6a |
| card-userdata.zip | 94,305 B | 7a5ba950097bf0b4c87ff73819c647f3913dbb755a7c8f0685c9286426002f9c |

校验：四个资产与 SHA256SUMS.release 同目录，执行 `sha256sum -c SHA256SUMS.release`。
各版本变更与限制见 [docs/releases.md](docs/releases.md)，卡布局与上电见
[docs/board-usage.md](docs/board-usage.md)。ko/fogccc-irq.ko 与镜像内核按
vermagic=6.18.10-xilinx-g4f7afe14f724 配对。

## 6. 目录与调试

```
rtl/       顶层 + 寄存器 + BFS 引擎 + 位图/队列/free-list/脏 FIFO + AXI 读
sim/       自检 testbench、定向 TB、AXI 协议检查器
csrc/      驱动、test_main、Python BFS 参照
driver/    IRQ_F2P 内核模块
python/    ctypes 绑定
vivado/    BD + 综合/实现脚本
petalinux/ 镜像配方与构建脚本
tools/     串口与上板脚本、测试、日志
artifacts/ 卡上产物与二进制清单（BOOT.BIN/image.ub 不入库）
skill/     技能包
report/    大模型协作记录（设计报告本地定稿后入库）
docs/      构建、上板、测量、仿真、设计细节
tests/     仓库契约测试
```

选题指南 3.3.5.4 的推荐结构与本仓库的对应关系如下。本仓库未采用推荐目录名，按该节要求在此给出对照；
所有目录名为小写英文，不含空格与中文字符。

| 指南推荐 | 本仓库 | 内容 |
| --- | --- | --- |
| README.md | README.md | 项目简介与复现步骤 |
| src/ | rtl/、csrc/、driver/、python/ | PL 源码、C 驱动与 test_main、内核模块、ctypes 绑定 |
| sim/ | sim/ | 自检 testbench、定向用例、AXI 协议检查器 |
| build/ | vivado/、petalinux/、Makefile | 位流与镜像的构建脚本、综合与实现报告 |
| board/ | tools/、tools/logs/ | 串口与上板脚本、逐次实测日志 |
| data/ | artifacts/ | 卡上产物、二进制清单与校验值 |
| skill/ | skill/ | 技能包，索引见 skill/README.md |
| report/ | report/、docs/ | 大模型协作记录；设计报告本地定稿后随批次入库；设计、测量、仿真、发布记录见 docs/ |

tests/ 为仓库自身的契约测试（目录规范、提交信息、字面量基线），不属于上述结构。
本仓库没有独立的 data/：测试数据由脚本运行时生成；board/ 对应 tools/ 与 tools/logs/。
目录名统一小写；README、LICENSE、NOTICE、Makefile 与 BitBake 的 %.bbappend 属工具链约定，保留原样。

完整目录说明见 [docs/build.md](docs/build.md)。调试：标记结果/周期/队列在 0x10/0x14/0x18/0x1C，
对象图在 DDR 0x1E000000；内部信号可用 ILA（vivado/build.tcl 加 system_ila）。

## 7. License

MIT（见 LICENSE）。例外与第三方组件见 [NOTICE](NOTICE)。
