# FPGA Offload GC Coprocessor（FOGCCC）

[![Platform](https://img.shields.io/badge/Platform-Xilinx%20Zynq--7000%20XC7Z100-blue)](#1-结果)
[![RTL](https://img.shields.io/badge/RTL-Verilog%202001-green)](#3-设计与接口)
[![Vivado](https://img.shields.io/badge/Vivado-2026.1-orange)](docs/build.md)
[![License](https://img.shields.io/badge/License-MIT-yellow)](#7-license)
[![CI](https://github.com/HiEq/FPGA-Offload-GC-Coprocessor/actions/workflows/lint.yml/badge.svg)](https://github.com/HiEq/FPGA-Offload-GC-Coprocessor/actions/workflows/lint.yml)
[![Release](https://img.shields.io/badge/release-v4.14-blue)](https://github.com/HiEq/FPGA-Offload-GC-Coprocessor/releases/tag/v4.14)

<p align="center"><img src="docs/images/zynq7100-render.jpg" width="720" alt="XC7Z100 载板 3D 渲染（示意）"></p>

**面向托管堆的 FPGA GC 协处理器（Zynq-7000 原型）**

| 构件 | 作用 |
|---|---|
| 语义解耦旁表 | 对象体留在 DDR，引用关系整理为连续旁表，标记只读旁表 |
| 多流乱序访存协处理器 | 两条 AXI HP 读流并发预取对象头与引用，合计 8 笔未完成读 |
| 扁平化数据流标记引擎 | 根集、广度优先队列与脏引用汇入同一条取数—判位—入队流水 |

标记与空闲扫描由 PL 完成，建图、启动与回收决策由 PS 负责；对象数上限 4096、图区上限 1 MiB，当前未接入语言运行时，回收采用全局暂停方式。当前发布 v4.14（2026-11-04，位流 md5 6D479244…）。

| 文档 | 内容 |
| --- | --- |
| [构建与目录](docs/build.md) | 工具链、构建步骤、仓库布局 |
| [上板与串口](docs/board-usage.md) | 烧录、卡布局、板上测试 |
| [测量口径](docs/measurement.md) | 测量条件、规模扫描、证据边界 |
| [设计与协议](docs/design-details.md) | 旁表、读通路、脏引用协议 |
| [证据日志](tools/logs/README.md) | 逐条命令、位流与镜像哈希 |

CI 只做静态检查与定向仿真，**不做** Vivado 综合/实现、xsim、PetaLinux 或上板。

---

## 1. 结果

| 对比对象 | 测量条件 | 每对象 | FPGA 加速比 |
|---|:---|---:|---:|
| **FPGA 标记**（fpga_vs_c_vs_python.py）| 同一张图，4000 对象 | **171 ns** | — |
| C，非预取（逐条读 DDR）| 同一张图、同一 BFS | 541 ns | **≈3.2×** |
| C，缓存友好（堆副本）| 堆上的副本 | 164 ns | **≈1.0×** |
| Python 脚本 BFS（逐条读 /dev/mem）| 同一张图 | 37.9 µs | **≈220×** |

FPGA 列只计标记引擎时间（周期计数 / 100 MHz），不含建图与驱动开销；171 ns 以已标记的 3766 个对象为分母。结果限于 4096 对象 / 1 MiB 图、单层 DDR；规模扫描、端到端成本与证据边界见 [docs/measurement.md](docs/measurement.md)。

C/DMA 建图把 4000 对象的建图从 102.2 ms 降到 2.0–5.4 ms，端到端 2.7–6.0 ms（17–38×）；命令、脚本与逐条日志见 [tools/build_routes/README.md](tools/build_routes/README.md)。

---

## 2. 快速开始

```bash
# 位流（PC）
vivado -mode batch -source vivado/build.tcl

# 板上二进制（PC，PetaLinux SDK）
SDK_ENV=<sdk> ./csrc/build_c_bins.sh
SDK_ENV=<sdk> ./csrc/build_routes/build_c.sh
SDK_ENV=<sdk> KERNEL_BUILD=<linux build dir> ./csrc/build_routes/build_dma.sh
```

```sh
# 板上自检（USERDATA 根目录）
sh fpga_vs_python.sh 4096 8 2
sh fpga_build_routes.sh

# 宿主回归
python -m unittest discover -s tests -p "test_*.py"
```

完整构建、烧录、串口与上板步骤见 [docs/build.md](docs/build.md)、[docs/board-usage.md](docs/board-usage.md)。

---

## 3. 设计与接口

三个构件的分工见开头与 [docs/design-details.md](docs/design-details.md)；这里只列软件可见的寄存器与关键参数。

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

DIRTY_PUSH 用 0x440（根表止于 0x43F）；CTRL[5] 与 DIRTY_* 的完整契约见 [docs/design-details.md](docs/design-details.md)。

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

---

## 4. 证据

| 项目 | 结果 |
|---|---|
| 标记正确性 | test_main 3/3、随机图 8/8、abort 11/11 |
| C/DMA 建图 | C_BUILD_RESULT OK、DMA_BUILD_RESULT OK、卡上 BUILD_ROUTES_DONE |
| 仿真 | 定向测试台全部通过；负控对修复前 RTL 失败 |

逐条日志、命令与判据见 [tools/logs/README.md](tools/logs/README.md)；仿真用例矩阵见 [docs/simulation.md](docs/simulation.md)。

---

## 5. 发布

当前发布 v4.14（GitHub Latest，800 MHz）。v4.7（667 MHz）为另一个正式版，其余版本为 Pre-release 历史快照。BOOT.BIN 与 image.ub 不入库，随 Release 发布（再分发限制见 [NOTICE](NOTICE)）；两个 zip 分别解压到 BOOT 与 USERDATA 根目录。

| 资产 | 大小 | SHA256 |
| --- | --- | --- |
| BOOT.BIN | 18,582,724 B | d20530bc3ddbfd01be9cacaeac30618d568b5ec6c180232dab64cf905a3898fd |
| image.ub | 47,762,547 B | c958eac9970c3a4ddeb333a98922169801b484c706bbd77cf6bc8cbfd29c329f |
| card-boot.zip | 5,176 B | 6844e8612cafca02cee44696ca6948ee345e1a2d2d11e7aaf77eac6a99764e6a |
| card-userdata.zip | 139,184 B | c3fa49376d0e75c60c939c8e3200b1961090f99476af452e53f2440fe3e38fd2 |

校验：四个资产与 SHA256SUMS.release 同目录，执行 `sha256sum -c SHA256SUMS.release`。各版本变更与限制见 [docs/releases.md](docs/releases.md)，卡布局与上电见 [docs/board-usage.md](docs/board-usage.md)。

---

## 6. 目录

选题指南 3.3.5.4 的推荐结构与本仓库的对应关系如下。本仓库未采用推荐目录名，按该节要求在此给出对照；所有目录名为小写英文，不含空格与中文字符。

| 指南推荐 | 本仓库 | 内容 |
| --- | --- | --- |
| README.md | README.md | 项目简介与复现步骤 |
| src/ | rtl/、csrc/、driver/、python/ | PL 源码、C 驱动与 test_main、C/DMA 建图验证、内核模块、ctypes 绑定 |
| sim/ | sim/ | 自检 testbench、定向用例、AXI 协议检查器 |
| build/ | vivado/、petalinux/、Makefile | 位流与镜像的构建脚本、综合与实现报告 |
| board/ | tools/、tools/logs/ | 串口与上板脚本、逐次实测日志 |
| data/ | artifacts/ | 卡上产物、二进制清单与校验值 |

tests/ 为仓库自身的契约测试（目录规范、提交信息、字面量基线），不属于上述结构。完整目录说明见 [docs/build.md](docs/build.md)。

---

## 7. License

MIT（见 LICENSE）。例外与第三方组件见 [NOTICE](NOTICE)。
