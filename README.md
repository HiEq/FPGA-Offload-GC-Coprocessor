<h1 align="center">FPGA Offload GC Coprocessor（FOGCCC）</h1>

<p align="center">
  <a href="#1-结果"><img src="https://img.shields.io/badge/Platform-Xilinx%20Zynq--7000%20XC7Z100-blue" alt="Platform"></a>
  <a href="#3-设计与接口"><img src="https://img.shields.io/badge/RTL-Verilog%202001-green" alt="RTL"></a>
  <a href="docs/build.md"><img src="https://img.shields.io/badge/Vivado-2026.1-orange" alt="Vivado"></a>
  <a href="#6-license"><img src="https://img.shields.io/badge/License-MIT-yellow" alt="License"></a>
  <a href="https://github.com/HiEq/FPGA-Offload-GC-Coprocessor/actions/workflows/lint.yml"><img src="https://github.com/HiEq/FPGA-Offload-GC-Coprocessor/actions/workflows/lint.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/HiEq/FPGA-Offload-GC-Coprocessor/releases/tag/v5.0"><img src="https://img.shields.io/badge/release-v5.0-blue" alt="Release"></a>
</p>

<p align="center">
  <img src="docs/images/block.png" width="640" alt="FOGCCC 系统架构">
</p>

面向托管堆的 FPGA GC 协处理器：对象体留在 DDR，引用关系导出为连续旁表，
标记由 PL 完成；建图、启动与回收决策由 PS 负责。当前版本 v5.0 支持
1,048,576 个对象与 64 MiB 图区，并通过 JamVM 适配器接入真实 Java 负载。

---

## 1. 结果

| 指标 | 测量条件 | 硬件 | 原版 JamVM | 比值 |
|---|---|---:|---:|---:|
| 纯 mark | `G1M 1000000`，700 MB 固定堆 | **73.9 ms** | 350 ms | **4.7×** |
| 整次 GC 停顿 | 同上，稳态增量轮 | **256 ms** | 428 ms | **1.67×** |
| DaCapo 纯 mark | 9.12-MR1 `-s small`，6 个基准 | **2.9–8.3 ms** | 66.8–75.4 ms | **9.6–23×** |

数据集与命令见 [docs/jvm-adapter.md](docs/jvm-adapter.md)；日期 2026-11-08，
tag `v5.0`，`libjvm.so` md5 `d52939ee1d82b6cb0c2ec5b3120808bb`。DaCapo 6/6
通过、6/6 `verify_extra=0`；端到端与原版相差 0.0–2.4%。4000 对象的旧版
微基准（171 ns/对象，100 MHz）见 [docs/performance-history.md](docs/performance-history.md)。

标记正确性、C/DMA 建图与仿真结果见 [tools/logs/README.md](tools/logs/README.md)。

---

## 2. 系统构成

- **语义解耦旁表**：对象体留在 DDR，引用关系整理为连续旁表，标记只读旁表。
- **多流乱序访存协处理器**：两条 AXI HP 读流并发预取对象头与引用，合计 8 笔未完成读。
- **扁平化数据流标记引擎**：根集、广度优先队列与脏引用汇入同一条取数—判位—入队流水。
- **JamVM 适配器**：宿主对象图导出为连续旁表，硬件标记位图按 id 导入 JVM 标记位，不改 JVM 核心。

---

## 3. 设计与接口

旁表格式、读通路与脏引用协议见 [docs/design-details.md](docs/design-details.md)；
寄存器映射与关键参数见下方折叠块，规则以 `csrc/fpga_gc.h` 与 `rtl/gc_regs.v` 为准。

<details>
<summary><b>寄存器映射与关键参数</b></summary>

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
| 0x20 | STATUS | R | [0] 队列溢出 · [1] AXI 读错误 · [2] 引用失步 · [3] 坏对象头 · [4] 引擎空闲 · [5] 空闲链表扫描忙 · [6] 位图转储忙 · [7] 上次启动后完成过转储 |
| 0x24 | BM_ADDR | R/W | 位图探针字地址（0–32767，引擎空闲时有效） |
| 0x28 | BM_DATA | R | 位图探测数据（2 拍延迟；读后勿改 BM_ADDR）|
| 0x30 | MAGIC | R | 固定 0x47434343（"GCCC"）|
| 0x34 | VERSION | R | 固定 0x00070500（v5.0）|
| 0x38 | FREE_COUNT | R | 未标记对象数（标记完成后扫描，扫描期 STATUS[5]=1）|
| 0x3C | FREE_DATA | R | 读一次弹出一个 free 对象 ID |
| 0x40+ | ROOT_LIST | R/W | 根集 ID 数组（0x40–0x43F，最多 256 个）；读回用于写后校验 |
| 0x440 | DIRTY_PUSH | W/R | **W** 0xA5400000 \| (tag<<12) \| id（标记符 = WDATA[31:20]），tag 每次推送必须变化；**R** 当前 FIFO 占用 |
| 0x444 | DIRTY_STAT | R | [8:0] 占用 · [9] 溢出（粘滞）· [10] 待处理 · [19:16] 最后接受的 tag · [31:20] 最后接受的 id |
| 0x448 | DIRTY_DRAINED | R | 本轮已消费条数（每次 start 清零）|
| 0x44C | DIRTY_PUSHED | R | 自上次清空以来接受的条数 |
| 0x450 | DIRTY_POPPED | R | 自上次清空以来弹出的条数 |
| 0x454 | Q_HWM | R | 上一轮 BFS 队列峰值占用 |
| 0x458 | Q_HI | R | 队列占用 ≥64 的周期数（宽前沿）|

| 参数 | 值 | 说明 |
| --- | --- | --- |
| MAXO | **8** | 未完成读上限，等于 PS7 S_AXI_HP0 的 NUM_READ_OUTSTANDING |
| QD | **80** | 每条流的命令/数据 FIFO 容量 |
| PD | **8** | 对象头暂存环深度 = 预取深度 |
| DQD | **16** | 引用描述符队列深度 |
| 对象上限 | **1048576** | 20 位 ID / 位图 1,048,576 位 / 队列 524,288 深 |
| AXI 协议 | **AXI3** | HP 口原生：ID_WIDTH=6、单拍、ARSIZE=3 |
| 流 ID | **0 = 引用, 1 = 对象头** | 同 ID 保序，异 ID 互不阻塞 |
| 时钟 | **FCLK0 = 150MHz** | 单时钟域，无 CDC；WNS +0.012 / WHS +0.056 |
| 位图 / 队列 | 1,048,576 bit（2 库）/ 524,288×20 | 1 Mb / 10 Mb |

</details>

---

## 4. 文档

| 文档 | 内容 |
| --- | --- |
| [构建与目录](docs/build.md) | 工具链、构建步骤、仓库布局 |
| [上板与串口](docs/board-usage.md) | 烧录、卡布局、板上测试 |
| [测量口径](docs/measurement.md) | 测量条件、规模扫描、证据边界 |
| [设计与协议](docs/design-details.md) | 旁表、读通路、脏引用协议 |
| [JVM 适配器](docs/jvm-adapter.md) | 构建、运行参数、STW 与 DaCapo 结果 |
| [性能历史](docs/performance-history.md) | 历史版本与每步优化 |
| [发布记录](docs/releases.md) | 每个版本的变更、验证与限制 |
| [证据日志](tools/logs/README.md) | 逐条命令、位流与镜像哈希 |

CI 只做静态检查与定向仿真，**不做** Vivado 综合/实现、xsim、PetaLinux 或上板。
快速开始与完整复现步骤见 [docs/build.md](docs/build.md)。

---

## 5. 发布

当前版本 v5.0（1M 对象 / 64 MiB 图区 / 150 MHz）。BOOT.BIN 与 image.ub
不入库，随 Release 发布（再分发限制见 [NOTICE](NOTICE)）；两个 zip 分别
解压到 BOOT 与 USERDATA 根目录。各版本的变更与限制见
[docs/releases.md](docs/releases.md)。

<details>
<summary><b>SHA256（点击展开）</b></summary>

| 资产 | 大小 | SHA256 |
| --- | --- | --- |
| BOOT.BIN | 18,582,724 B | 2523e66e71bad79880ab14ed93a185e38834b58bb7487fd56c85e46127364139 |
| image.ub | 47,759,016 B | 710564ad379b07d5f818ce248a8b59ae97b109caa4cd7959c9741ffaf9e0ca2e |
| card-boot.zip | 5,920 B | efaa03ffef6e26bc8cc56bb9b7b9faadcad04b535dc4a67eb8a96f95a55d865b |
| card-userdata.zip | 139,184 B | c7c9fceaa947990eb88e17f8dbcaed3c8386964bd6fa64f946d3f947a902eceb |

</details>

校验：四个资产与 SHA256SUMS.release 同目录，执行 `sha256sum -c SHA256SUMS.release`。

---

## 6. License

MIT（见 LICENSE）。例外与第三方组件见 [NOTICE](NOTICE)。
