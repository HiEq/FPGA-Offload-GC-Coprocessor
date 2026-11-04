# FPGA Offload GC Coprocessor（FOGCCC）

[![Platform](https://img.shields.io/badge/Platform-Xilinx%20Zynq--7000%20XC7Z100-blue)](#1-结果)
[![RTL](https://img.shields.io/badge/RTL-Verilog%202001-green)](#3-设计与接口)
[![Vivado](https://img.shields.io/badge/Vivado-2026.1-orange)](docs/build.md)
[![License](https://img.shields.io/badge/License-MIT-yellow)](#7-license)
[![CI](https://github.com/HiEq/FPGA-Offload-GC-Coprocessor/actions/workflows/lint.yml/badge.svg)](https://github.com/HiEq/FPGA-Offload-GC-Coprocessor/actions/workflows/lint.yml)

面向托管堆的 FPGA GC 协处理器（Zynq-7000 原型）。设计由三个构件组成：**语义解耦旁表**把对象体与引用关系分开，对象体留在 DDR，引用关系整理为连续旁表；**多流乱序访存协处理器**用两条独立读流并发预取对象头与引用，同流保序、跨流可乱序返回；**扁平化数据流标记引擎**把根集、广度优先队列与脏引用汇入同一条取数—判位—入队流水。

标记与空闲对象扫描由 PL 完成，分配、引用更新与回收策略由 PS 侧软件负责。本仓库提供寄存器映射、驱动接口与上板验证；回收采用全局暂停方式，对象数上限 4096、图区上限 1 MiB，当前未接入语言运行时，测量范围限于标记与空闲扫描两个阶段。

当前证据：位流 6D479244…、BOOT.BIN d20530bc…、image.ub c958eac9…（v4.14，2026-11-04）。
原始日志在 tools/logs/（索引 [tools/logs/README.md](tools/logs/README.md)）；
测量条件与证据边界见 [docs/measurement.md](docs/measurement.md)。
CI 只做静态检查与定向仿真，**不做** Vivado 综合/实现、xsim、PetaLinux 或上板。

Contents: [结果](#1-结果) · [快速开始](#2-快速开始) · [设计与接口](#3-设计与接口) ·
[证据](#4-证据) · [发布](#5-发布) · [目录与调试](#6-目录与调试) · [License](#7-license)

详细文档：[上板/串口](docs/board-usage.md) · [构建与平台](docs/build.md) ·
[测量条件](docs/measurement.md) · [仿真矩阵](docs/simulation.md) ·
[设计细节](docs/design-details.md) · [全部文档](docs/README.md)

## 1. 结果

| 对比对象 | 测量条件 | 每对象 | FPGA 加速比 |
|---|---|---|---|
| **FPGA 标记**（fpga_vs_c_vs_python.py）| 同一张图，4000 对象 | **171 ns** | — |
| C，非预取（逐条读 DDR）| 同一张图、同一 BFS | 541 ns | **≈3.2×** |
| C，缓存友好（堆副本）| 堆上的副本 | 164 ns | **≈1.0×** |
| Python 脚本 BFS（逐条读 /dev/mem）| 同一张图 | 37.9 µs | **≈220×** |

FPGA 列只含标记引擎时间（周期计数 / 100 MHz），不含建图与驱动开销；171 ns 以已标记的 3766 个
对象为分母（645.4 µs / 4000 = 161 ns）。最后一列为 FPGA 加速比（该实现时间 / FPGA 时间），1.0× 表示与 FPGA 相当；同一张图重复运行时 Python 列的比值在 215×–222× 之间，表里取归档的一次。
四行来自同一张图（tests/fpga_vs_c_vs_python.py，v4.12 / PS 800 MHz）；逐项测量条件与证据见
[docs/measurement.md](docs/measurement.md)。test_main 只查计数正确性。

**范围**：所有结果来自 4096 对象 / 1 MiB 图、单层 DDR；没有规模扫描，也没有 L1/LLC/OCM 分级。
1 MiB 工作集接近 L2、TLB 全命中，是 CPU 最有利的区间，因此“超出 LLC 才有优势”是延迟推理的
假设而不是已测结论；只计标记阶段，建图本身约为标记的 15×。

**实现范围**：全局暂停，写 START、轮询 DONE。旁表由 csrc/fpga_gc.c /
python/fogccc.py 按「对象头 + 引用数组」布局构造；**未接入**任何语言运行时的 gc 模块。

### 建图路径（C / DMA）

标记阶段之外，建图也可以由 C 或 DMA 完成。同一张 4000 对象图、`avg_refs=3`：

| 建图路径 | 建图 | 端到端（+0.645 ms 标记）| 相对 Python 建图 102.85 ms |
|---|---|---|---|
| C 直接写 `/dev/mem` | 4.97–5.38 ms | 5.61–6.03 ms | 17–18× |
| C 缓存构建 + 一次 `memcpy` | 2.04–2.08 ms | 2.69–2.73 ms | 38× |
| PS PL330 DMA（coherent staging）| 2.25–5.35 ms | 2.90–6.00 ms | 17–36× |

端到端只含“建图 + 标记”，不含驱动、轮询与回读；DMA 是 **PS → PL330 mem-to-mem**，
不是 PL AXI DMA。四路表中的 FPGA / C / Python 标记基线不变。命令与日志见
[tools/build_routes/README.md](tools/build_routes/README.md)。

## 2. 快速开始

```powershell
# 位流（PC）
vivado -mode batch -source vivado/build.tcl
```

```bash
# 板上二进制（PC，PetaLinux SDK）
SDK_ENV=<sdk> ./csrc/build_c_bins.sh      # test_main / libfogccc.so
SDK_ENV=<sdk> ./csrc/build_routes/build_c.sh                     # C/DMA 建图三个程序
SDK_ENV=<sdk> KERNEL_BUILD=<linux build dir> ./csrc/build_routes/build_dma.sh  # fogccc_dma.ko
```

卡布局、烧录与上电步骤见 [docs/board-usage.md](docs/board-usage.md)；平台规格、工具链版本、
资源与时序见 [docs/build.md](docs/build.md)。

板上自检：

```sh
cd /run/media/USERDATA-mmcblk0p2
sh fpga_vs_c.sh                     # test_main 3 项（FPGA vs C 计数）
sh fpga_vs_python.sh 4096 8 2       # 8 张随机图，判据 PASSED (all invariants): 8/8
sh fpga_vs_python_repeat.sh 10      # 10 个种子 + 固定种子 5 次，判据 REPEAT_DONE
python3 tests/fpga_vs_c_vs_python.py  # 同一张图：FPGA / C（非预取）/ C（缓存友好）/ Python
sh fpga_build_routes.sh             # C/DMA 建图验证 + 两组四路对比，判据 BUILD_ROUTES_DONE
```

宿主回归：

```bash
python -m unittest discover -s tests -p "test_*.py"   # 仓库契约
```

```powershell
powershell -File tools/reproduce_all.ps1             # 六组 xsim + 清单 + PS 单测
```

## 3. 设计与接口

### 三个构件

| 构件 | 作用 | 实现 |
|---|---|---|
| 语义解耦旁表 | 对象体与引用关系分离，标记只读旁表 | 每对象 16 B 对象头 + 连续 u32 引用数组（0xFFFFFFFF 结尾）|
| 多流乱序访存协处理器 | 隐藏 DDR 延迟 | 引用流与对象头流两条 AXI 读流，合计 8 个未完成读 |
| 扁平化数据流标记引擎 | 单条流水完成标记 | 根集、广度优先队列、脏引用 FIFO 共用取数—判位—入队 |

对象体不被标记过程修改；PS 侧只负责建图、写寄存器与回收策略。

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
| 0x20 | STATUS | R | [0] 队列溢出 · [1] AXI 读错误 · [2] 引用失步 · [3] 坏对象头 · [4] 引擎空闲 · [5] 空闲链表扫描忙 |
| 0x24 | BM_ADDR | R/W | 位图探针地址（0–4095，引擎空闲时有效） |
| 0x28 | BM_DATA | R | 位图探测数据（2 拍延迟；读后勿改 BM_ADDR）|
| 0x30 | MAGIC | R | 固定 0x47434343（"GCCC"）|
| 0x34 | VERSION | R | 固定 0x0004_0301（v4.5 起）|
| 0x38 | FREE_COUNT | R | 未标记对象数（标记完成后扫描，扫描期 STATUS[5]=1）|
| 0x3C | FREE_DATA | R | 读一次弹出一个 free 对象 ID |
| 0x40+ | ROOT_LIST | R/W | 根集 ID 数组（0x40–0x43F，最多 256 个）；读回用于写后校验 |
| 0x440 | DIRTY_PUSH | W/R | **W** 0xA5400000 \| (tag<<12) \| id（标记符 = WDATA[31:20]），tag 每次推送必须变化；**R** 当前 FIFO 占用 |
| 0x444 | DIRTY_STAT | R | [8:0] 占用 · [9] 溢出（粘滞）· [10] 待处理 · [19:16] 最后接受的 tag · [31:20] 最后接受的 id |
| 0x448 | DIRTY_DRAINED | R | 本轮已消费条数（每次 start 清零）|
| 0x44C | DIRTY_PUSHED | R | 自上次清空以来接受的条数 |
| 0x450 | DIRTY_POPPED | R | 自上次清空以来弹出的条数 |

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

### 语义解耦旁表

```
@ obj_base + k*16:                @ ref_addr:
┌──────────────────────┐          ┌──────────────────────────┐
│ +0:  uint32 obj_id   │          │ [ref0][ref1]...[0xFFFF]  │
│ +4:  uint32 ref_count│          │                          │
│ +8:  uint32 ref_addr │──────────┘                          │
│ +12: uint32 reserved │          └──────────────────────────┘
└──────────────────────┘
```

旁表由对象头数组与引用数组组成：对象头 16 B 一个，记录对象 ID、出度与引用数组地址；引用数组以 0xFFFFFFFF 结尾。标记引擎先读对象头取 ref_count 与 ref_addr，再按 ref_addr + j*4 读第 j 个引用；对象体只在软件分配与回收时访问。

### 多流乱序访存协处理器

读通路按流 ID 分成两条：0 为引用，1 为对象头。同一流内保序，跨流可乱序返回；每条流各有命令 FIFO 与数据 FIFO（深 80），合计最多 8 个未完成读。对象头预取环深 4，引用描述符队列深 8；DDR 延迟由预取覆盖，标记流水不等待单条返回。

### 扁平化数据流标记引擎

引擎没有微码，也没有递归栈：根集、广度优先队列与脏引用 FIFO 是同一取数—判位—入队流水的三个入口。取到对象头后按引用数组展开；目标未标记则置位并计数，已标记则跳过；队列满时置溢出位，不做静默丢弃。

脏引用 FIFO 是第二工作源：写 0x440 推入一个 ID，未标记则置位并计数，已标记则强制重扫但不计数；结束条件要求队列与 FIFO 同时为空。回收按「全量标记 → 增量标记（应用线程可并发推送）→ 收口重标」三轮进行；FIFO 满 256 时丢弃并置溢出位，软件见溢出退回全量标记。协议、屏障顺序、回执与并发证据见 [docs/design-details.md](docs/design-details.md)。

## 4. 证据

| 套件 | 结果 |
|---|---|
| 冷启动 D1..D6 / test_main | 0 / 3/3（证据为 v4.5 镜像；卡上当前为 v4.14，镜像同 v4.13）|
| 阶段 2 / 阶段 3 | PHASE2_PASS、CONTRACT_RESULT OK、dirty 全套 OK、收尾 occ=0 |
| fpga_vs_python.sh 4096 8 2 | 8/8 |
| abort_test / abort_sweep / done_race | T1–T5 / 11/11 / P3 失配 0/20（20/20 正确）|
| fpga_vs_c_vs_python.py（同一张图的四路对比）| THREE_WAY_RESULT OK |
| 建图路径 C / DMA（4000 对象）| C_BUILD_RESULT OK、DMA_BUILD_RESULT OK、C/DMA_FOUR_WAY_RESULT OK、卡上 BUILD_ROUTES_DONE |
| tb_flush_data / tb_stale_ar_flush / tb_start_while_busy | PASS（负控对修复前 RTL 全部 FAIL）|

日志索引与逐条出处：[tools/logs/README.md](tools/logs/README.md)。
建图日志：`tools/logs/board_build_routes_c.log`、`tools/logs/board_build_routes_dma.log`、
`tools/logs/board_build_routes_four_way_c.log`、`tools/logs/board_build_routes_four_way_dma.log`、
`tools/logs/board_build_routes_card.log`、`tools/logs/board_build_routes_card_actual.log`。
仿真用例矩阵：[docs/simulation.md](docs/simulation.md)。

## 5. 发布

当前发布 v4.14（GitHub Latest，800 MHz）。v4.7（667 MHz）为另一个正式版；其余版本为 Pre-release
历史快照。v4.14 新增 C/DMA 建图验证源码、脚本与日志，标记引擎与镜像未变，BOOT.BIN 与 image.ub
与 v4.13 相同；card-userdata.zip 相应增加三个程序和 fogccc_dma.ko。

BOOT.BIN 与 image.ub 不入库，随 Release 发布（再分发限制见 [NOTICE](NOTICE)）。
BOOT.BIN、image.ub 放 BOOT 分区根目录；card-boot.zip 与 card-userdata.zip 分别解压到
BOOT 与 USERDATA 根目录。

| 资产 | 大小 | SHA256 |
| --- | --- | --- |
| BOOT.BIN | 18,582,724 B | d20530bc3ddbfd01be9cacaeac30618d568b5ec6c180232dab64cf905a3898fd |
| image.ub | 47,762,547 B | c958eac9970c3a4ddeb333a98922169801b484c706bbd77cf6bc8cbfd29c329f |
| card-boot.zip | 5,176 B | 6844e8612cafca02cee44696ca6948ee345e1a2d2d11e7aaf77eac6a99764e6a |
| card-userdata.zip | 139,184 B | c3fa49376d0e75c60c939c8e3200b1961090f99476af452e53f2440fe3e38fd2 |

校验：四个资产与 SHA256SUMS.release 同目录，执行 `sha256sum -c SHA256SUMS.release`。
各版本变更与限制见 [docs/releases.md](docs/releases.md)，卡布局与上电见
[docs/board-usage.md](docs/board-usage.md)。ko/fogccc-irq.ko 与镜像内核按
vermagic=6.18.10-xilinx-g4f7afe14f724 配对。

## 6. 目录与调试

```
rtl/       顶层、寄存器、扁平化标记引擎、位图/队列/空闲链表/脏引用 FIFO、多流读通路
sim/       自检与定向测试台、AXI 协议检查器
csrc/      驱动、test_main、Python 广度优先参照、build_routes/（C/DMA 建图）
driver/    IRQ_F2P 内核模块、fogccc_dma/（建图暂存）
python/    Python 绑定（ctypes）
vivado/    BD + 综合/实现脚本
petalinux/ 镜像配方与构建脚本
tools/     串口与上板脚本、测试、build_routes/、日志
artifacts/ 卡上产物与二进制清单（BOOT.BIN/image.ub 不入库）
docs/      构建、上板、测量、仿真、设计细节
tests/     仓库契约测试
```

选题指南 3.3.5.4 的推荐结构与本仓库的对应关系如下。本仓库未采用推荐目录名，按该节要求在此给出对照；
所有目录名为小写英文，不含空格与中文字符。

| 指南推荐 | 本仓库 | 内容 |
| --- | --- | --- |
| README.md | README.md | 项目简介与复现步骤 |
| src/ | rtl/、csrc/、driver/、python/ | PL 源码、C 驱动与 test_main、C/DMA 建图验证、内核模块、ctypes 绑定 |
| sim/ | sim/ | 自检 testbench、定向用例、AXI 协议检查器 |
| build/ | vivado/、petalinux/、Makefile | 位流与镜像的构建脚本、综合与实现报告 |
| board/ | tools/、tools/logs/ | 串口与上板脚本、逐次实测日志 |
| data/ | artifacts/ | 卡上产物、二进制清单与校验值 |

tests/ 为仓库自身的契约测试（目录规范、提交信息、字面量基线），不属于上述结构。
本仓库没有独立的 data/：测试数据由脚本运行时生成；board/ 对应 tools/ 与 tools/logs/。
目录名统一小写；README、LICENSE、NOTICE、Makefile 与 BitBake 的 %.bbappend 属工具链约定，保留原样。

完整目录说明见 [docs/build.md](docs/build.md)。调试：标记结果/周期/队列在 0x10/0x14/0x18/0x1C，
对象图在 DDR 0x1E000000；内部信号可用 ILA（vivado/build.tcl 加 system_ila）。

## 7. License

MIT（见 LICENSE）。例外与第三方组件见 [NOTICE](NOTICE)。
