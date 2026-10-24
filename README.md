# FPGA Offload GC Coprocessor（FOGC²）

[![Platform](https://img.shields.io/badge/Platform-Xilinx%20Zynq--7000%20XC7Z100-blue)](#platform)
[![RTL](https://img.shields.io/badge/RTL-Verilog%202001-green)](#3-设计与接口)
[![Vivado](https://img.shields.io/badge/Vivado-2026.1-orange)](#2-快速开始)
[![License](https://img.shields.io/badge/License-MIT-yellow)](#7-license)
[![CI](https://github.com/HiEq/FPGA-Offload-GC-Coprocessor/actions/workflows/lint.yml/badge.svg)](https://github.com/HiEq/FPGA-Offload-GC-Coprocessor/actions/workflows/lint.yml)

> `CI` 只做静态检查与定向回归（shell/Python/PowerShell 语法、`iverilog` RTL 解析、`gcc -fsyntax-only`、
> `SHA256SUMS`、`tb_runstart_race` / `tb_cmdfifo_flush`），**不做 Vivado 综合/实现、xsim、PetaLinux 或上板**。
> 证据口径与边界见 [`docs/measurement.md`](docs/measurement.md)；详细文档索引见 [`docs/`](docs/README.md)。
>
> **位流 ↔ 证据**：`artifacts/BOOT.BIN` 携带**位流 `3D3A9F1D…`**（BOOT sha256 `63e52587…`；
> `DIRTY_STAT[31:20]` = 最后接受的 id，见 AGENTS #20），已写卡并回读一致。
> 该镜像在 2026-10-24 **冷启动复验**：`irq` / `D1..D6` / 阶段 2·3 全链 / dirty 家族 /
> `gc`·`abort`·`sweep`·`done_race` / `repeat` / `cmark` 全绿，`tools/logs/` 下各套件即其证据；
> 三处 hand-over 竞态（AGENTS #21）由 `tb_flush_data` / `tb_stale_ar_flush` / `tb_start_while_busy` 守护。
> 历史负控日志仍属 `81F2C277…`（见 `tools/logs/README.md`）。

Contents: [项目与平台](#1-项目与平台) · [快速开始](#2-快速开始) · [设计与接口](#3-设计与接口) ·
[正确性、性能与测量](#4-正确性性能与测量) · [发布与上板](#5-发布与上板) ·
[调试](#6-调试与监控) · [License](#7-license) · [详细文档 `docs/`](docs/README.md)

把 GC 的**标记阶段**卸载到 Zynq-7000 PL：BFS 指针追逐由硬件完成，对象图放在DDR内。

| 对比对象 | 口径 | 每对象 | FPGA速度对比此项 |
|---|---|---|---|
| **FPGA 标记**（`test_main`，位流 `3D3A9F1D…`）| 4000 对象图 | **~171 ns** | — |
| **FPGA 标记**（`cmark`，位流 `3D3A9F1D…`）| 4096 对象梯度 | 17.5–20.6 拍 ≈ 175–206 ns | — |
| C，逐条读 DDR（未缓存，公平口径）| 同图同 BFS | 492–681 ns | **2.6–3.4× 更快** |
| C，数据驻留 cache | heap 副本 | 126–181 ns | **0.6–1.0×** |
| Python 脚本 BFS（逐条读 `/dev/mem`）| 同图 | — | **212–282×** |

> 引擎数字来自 `cmark` 扫描 `tools/logs/cmark_sweep.log`（4 组共 72 次）与 `test_main`
> （`tools/logs/board_test_main.log`），均为位流 `3D3A9F1D…` / BOOT `63e52587…`。
> `FPGA` 一列只含引擎时间（`CYCLES / 100 MHz`），不含构图与驱动开销；**cache 命中时要一起报**
> ——那是 C 的上限。完整口径与端到端成本见「正确性、性能与测量」。
>
> **实现范围**：stop-the-world，写 `START`、轮询 `DONE`；对象图由 `csrc/fpga_gc.c` /
> `python/fogccc.py` 按「对象头 + 引用数组」布局构造，**未接入**任何特定语言的运行时 `gc` 模块与对象布局。

## 1. 项目与平台

### 架构概览

```
┌─────────────────────────────────────────────────────────────┐
│                    Zynq-7000 XC7Z100                        │
│  ┌──────────────────────┐     ┌──────────────────────────┐  │
│  │   PS (ARM Cortex-A9) │     │   PL (FPGA Fabric)       │  │
│  │                      │     │                          │  │
│  │  Host app / SW       │     │  ┌────────────────────┐  │  │
│  │  ├── Software GC     │     │  │  gc_top            │  │  │
│  │  ├── fpga_gc.c       │AXI  │  │  ├── gc_regs       │  │  │
│  │  │   driver          ├────►│  │  ├── gc_mark_engine│  │  │
│  │  └── fogccc.py       │Lite │  │  │   (BFS FSM)     │  │  │
│  │       ctypes binding │     │  │  ├── gc_bitmap     │  │  │
│  │                      │AXI  │  │  │   (4096×32 BRAM)│  │  │
│  │  /dev/mem mmap       │◄───►│  │  ├── gc_queue      │  │  │
│  │                      │ HP  │  │  │   (4096×12 BRAM)│  │  │
│  │  Linux (PetaLinux)   │     │  │  └── gc_axi_read   │  │  │
│  └──────────────────────┘     │  └────────────────────┘  │  │
│                               └──────────┬───────────────┘  │
│                                          │ AXI HP (100MHz)  │
│                               ┌──────────▼───────────────┐  │
│                               │  DDR3 @ 533MHz           │  │
│                               │  0x1E000000: Object Graph│  │
│                               └──────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

> PL 顶层 `gc_top` 内部：`gc_regs`（寄存器）、`gc_mark_engine`（BFS FSM）、`gc_bitmap`（4096×32）、
> `gc_queue`（4096×12）、`gc_freelist`（阶段 2 扫描与 free 契约）、`gc_dirty_fifo`（阶段 3A/3B 脏集 + 并发增量标记）、
> `gc_axi_read`（AXI 读命令/数据 FIFO）。PS 侧：`fpga_gc.c` 驱动 + `fogccc.py` ctypes 绑定。

#### 工作流程

1. 宿主程序触发一次 GC 周期
2. C 驱动通过 `/dev/mem` 将对象图写入 DDR (`0x1E000000`)
3. C 驱动写 AXI-Lite 寄存器启动 FPGA 标记引擎
4. FPGA 引擎执行 BFS 标记
5. ARM PS 轮询完成标志，读取标记结果和周期计数
6. 宿主据此跳过/回收未标记对象

> **当前实现**：第 1、6 步由调用者负责，本仓库**未接入**任何特定语言的运行时 `gc` 模块。
> 对象图由 `csrc/fpga_gc.c` / `python/fogccc.py` 按「对象头 + 引用数组」布局构造；
> 标记语义与 GC 的 mark 阶段一致，回收动作由调用者完成。

### Platform

| 项目         | 规格                                                              |
| ------------ | ----------------------------------------------------------------- |
| FPGA         | Xilinx Zynq-7000 XC7Z100FFG900-**2**                |
| 逻辑单元     | 444K Logic Cells                                     |
| LUT / FF     | 277,400 CLB LUT ／ 554,800 CLB FF                |
| BRAM         | 26.5 Mb（755 × 36Kb）                                 |
| DSP          | 2,020 Slices                                         |
| PS CPU       | 2× ARM Cortex-A9 @666.67MHz |
| PS 内存      | DDR3 @ 533.33MHz                                  |
| 工具链       | Vivado 2026.1 / PetaLinux 2026.1                                  |
| 时钟域       | 单一时钟域 FCLK0 = 100MHz —— 引擎 / AXI-Lite / AXI HP 同一域，无 CDC |
| 实测资源占用 | LUT 26,924 (9.71%) ／ FF 71,460 (12.88%) ／ BRAM 5.5 (0.73%) ／ DSP 0 |
| 时序 | WNS +0.232 ns ／ WHS +0.054 ns                                    |
| AXI HP 位宽  | 64-bit（每次读 1 拍 = 2 个 32-bit 字，8 字节对齐 + 半字选择）     |

> 资源与时序数字来自 `vivado/build.tcl` 的实现报告；`fogccc_proj/` 不入库，可用该脚本重新生成。

#### 构建工具链版本

| 组件 | 版本 |
| --- | --- |
| Vivado（位流、JTAG） | 2026.1（SW Build 6511674） |
| PetaLinux | 2026.1（SDK `release-S06060014`） |
| 交叉编译器 | gcc 13.4.0（`arm-amd-linux-gnueabi-gcc`，`-mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard`） |
| GNU Make | 4.3 |
| CMake | 3.28.3（SDK 自带；本项目暂时不使用） |
| 构建主机 | Ubuntu 22.04.5 LTS（WSL2） |
| 目标 glibc | 2.39（发布镜像与 SDK sysroot 一致）|
| 目标 BusyBox / OpenSSL | 1.36.1 / 3.2.6 |
| 目标 Python | 3.12.12（仅标准库，无 numpy）|
| 内核 | linux-xlnx 6.18.10 |
| Bootloader | u-boot-xlnx 2026.01 |

构建要求：

1. `test_main` 与 `libfogccc.so` 用 SDK 交叉编译：`source environment-setup-cortexa9t2hf-neon-amd-linux-gnueabi` 后调用 `$CC`。
   三者（`test_main` / `libfogccc.so` / `cmark`）可一条命令构建：`SDK_ENV=<path> ./csrc/build_c_bins.sh`，
   产物直接写入 `artifacts/userdata/`；随后跑 `tools/make_manifest.ps1` 刷新 `artifacts/SHA256SUMS`。
2. 不使用根 `Makefile` 的 `CROSS=arm-linux-gnueabihf-`；PetaLinux 2026.1 SDK 提供的是 `arm-amd-linux-gnueabi-gcc`。
3. 产物须为 ARM：`file libfogccc.so` 输出包含 `ARM, EABI5`。
4. SDK sysroot 与发布镜像同为 glibc 2.39；按它链接即可。
5. Python 脚本仅使用标准库（`ctypes`、`mmap`、`struct`、`time`、`random`、`sys`）。

### 目录结构

```
FPGA-Offload-GC-Coprocessor/
├── rtl/                    Verilog RTL 源码
│   ├── gc_top.v            顶层 (AXI-Lite + AXI3 HP, 单时钟域无 CDC)
│   ├── gc_regs.v           AXI-Lite 寄存器接口 (12 位地址 / 含 STATUS)
│   ├── gc_mark_engine.v    BFS 状态机 + 对象头预取 + 引用发射器
│   ├── gc_bitmap.v         标记位图 BRAM 4096×32
│   ├── gc_queue.v          BFS 队列 BRAM 4096×12
│   ├── gc_freelist.v       阶段 2: free-list 扫描器 (扫描 + free 契约)
│   ├── gc_dirty_fifo.v     阶段 3A/3B: 脏边 FIFO + 并发增量标记工作源
│   └── gc_axi_read.v       AXI3 读主控: 双流 (ID=0 引用 / ID=1 对象头)
├── sim/                    xsim 自检仿真
│   ├── tb_gc_top.v         自检 testbench (主用例 + T1..T8 + T-ABORT/T-ABORT2/T-MAXFAN/T-ROOTCLAMP)
│   ├── axi_proto_check.v   AXI3 读通道协议检查器 (ARSIZE/ARLEN/ARBURST/对齐/VALID 稳定)
│   ├── run_sim.bat/.sh     只跑 tb_gc_top
│   ├── tb_axi_read.v       未完成读事务上限的定向测试 (+ run_axi_tb.bat/.sh)
│   ├── tb_runstart_race.v  同拍旧 R beat 定向测试 (+ run_race_tb.bat/.sh)
│   ├── tb_cmdfifo_flush.v  同拍命令 FIFO 定向测试 (+ run_cmdfifo_tb.bat/.sh)
│   └── lat_sweep.bat       延迟扫描 LAT=1..32
├── csrc/                   C 源码 (PS 端 Linux)
│   ├── fpga_gc.h / .c      驱动
│   ├── test_main.c         测试主程序 (4 项：正确性 / 周期 / 重复 / 重复根)
│   ├── py_bfs.py          Python BFS 参照（独立 oracle）
│   ├── cmark.c             C 基准源码（卡上二进制在 artifacts/userdata/cmark）
│   └── build_c_bins.sh     一次交叉编译 test_main / libfogccc.so / cmark
├── python/                 ctypes 绑定（fogccc.py）
├── vivado/
│   ├── build.tcl           BD + 综合 + 实现 + XSA
│   └── build_rtl_only.tcl  复用 BD
├── tools/                  宿主脚本
│   ├── serial_*.ps1 / push_tests.ps1  串口工具（run_gc / push / 整批推测试 / session）
│   ├── make_manifest.ps1 / make_card.ps1 / make_release_*.ps1
│   ├── reproduce_all.ps1    宿主侧一键复现（manifest + PS 单测 + xsim 组）
│   ├── tests/(功能测试)  debug/(调试工具)
│   └── logs/               证据日志（只留 README 引用的那些，见其中的 README.md）
├── driver/                 内核中断驱动 + PetaLinux 模块 recipe
├── petalinux/              工程骨架 (config/rootfs_config/meta-user) + 命令构建
├── artifacts/              要拷到 TF 卡的构建产物 + SHA256SUMS（二进制清单）
├── .github/workflows/      CI: lint + iverilog 定向回归 + gcc + SHA256SUMS 校验
├── docs/                   详细文档（口径/仿真/性能历史/上板速查），由 README 链接
├── AGENTS.md               本项目对 AI 参与者的工程约束
├── AGENT_NOTES_pitfalls.md bring-up 排错笔记（症状 → 判别方法）
├── petalinux/BUILD_GUIDE.md 构建步骤
└── README.md               本文件（只保留大头信息）
```

## 2. 快速开始

> 串口脚本自动识别 CH340；如果需要指定COM口可加 `-Port COMx`。
> 完整清单见 [`docs/board-usage.md`](docs/board-usage.md)。

### 1. 生成比特流 (PC 端)

```powershell
cd <repo>/vivado
vivado -mode batch -source build.tcl
```

产出: `fogccc_proj\fogccc_z7100.runs\impl_1\system_wrapper.bit`

> 构建期间可另开窗口运行 `tools\vivado_affinity.ps1`：综合阶段把 `synth_1`
> 子进程绑到 P-core（逻辑 CPU 2–3，综合以单线程为主），place/route 阶段放宽到
> `0xFFFFC`（留 CPU 0–1 给系统），优先级统一 `AboveNormal`；vivado 退出后自行结束。
> 脚本按子进程命令行里的运行目录识别阶段，无需手工切换。

### 2. 烧录 FPGA

**方式 A: Vivado Hardware Manager**
```
Open Hardware Manager → Auto Connect → Program Device → 选择 .bit
```

**方式 B: Linux 动态加载**
```bash
sudo cp system_wrapper.bit /lib/firmware/fogccc.bit
echo fogccc.bit > /sys/class/fpga_manager/fpga0/firmware
cat /sys/class/fpga_manager/fpga0/state
```

### 3. 编译并运行测试（需要在PC上交叉编译）

```bash
# PC: 用 PetaLinux SDK 交叉编译
source ~/petalinux_sdk/environment-setup-cortexa9t2hf-neon-amd-linux-gnueabi
$CC -O2 -o test_main csrc/fpga_gc.c csrc/test_main.c

# 拷到 USERDATA 分区后，在板上运行（需要 root）
cd /run/media/USERDATA-mmcblk0p2      # udev 开机挂在这里（stock /etc/fstab 不含 p2）；/mnt/userdata 需 sh mount_data.sh 或主机脚本自己挂
sudo ./bin/test_main
```

> 工具链版本见「Platform → 构建工具链版本」。根 `Makefile` 的
> `CROSS=arm-linux-gnueabihf-` 不适用于 PetaLinux 2026.1 SDK，改用 `$CC`。

### 4. Python 测试

板上没有 gcc，共享库在 PC 上交叉编译，卡上 `py/` 已随仓库提供：

```bash
# PC
source ~/petalinux_sdk/environment-setup-cortexa9t2hf-neon-amd-linux-gnueabi
$CC -O2 -shared -fPIC -o libfogccc.so csrc/fpga_gc.c
```

```bash
# 板上（把 libfogccc.so + fogccc.py 放到卡上 py/ 目录后）
cd /run/media/USERDATA-mmcblk0p2/py   # 或用 /mnt/userdata/py（见「测量口径」里的挂载说明）
python3 fogccc.py        # 三方对账：FPGA / C / 位图读回 + STATUS
```

## 3. 设计与接口

### Register Map

| 偏移 | 名称 | R/W | 说明 |
|------|------|-----|------|
| 0x00 | CTRL | R/W | [0]=start [1]=**保留**（旧 clear_bm，位图由引擎每轮自动清） [2]=clear_q [3]=abort（把引擎拉回 IDLE、清 DONE、清 BFS 队列与读流水线；仿真 `T-ABORT`/`T-ABORT2` 红→绿 + 板上 `abort_test.py` T1–T5 与 `abort_sweep.py` 11 个相位，`STATUS` 保持 0；驱动超时路径会写它） [4]=bm_keep（阶段 3A，**必须与 `[0]=start` 同一次写**） [5]=dirty_flush（阶段 3A；**只是"武装"**：在**下一次 `BM_KEEP=0` 的 START** 上生效、被增量（`BM_KEEP=1`）start 丢弃——本板会重投递 store 且副本不一定相邻，这样任何时序的迟到副本都不会静默丢记录） [31]=done |
| 0x04 | OBJ_BASE | R/W | 对象图 DDR 物理地址 |
| 0x08 | OBJ_COUNT | R/W | 对象总数 (最大 4096) |
| 0x0C | ROOT_COUNT | R/W | 根集数量（硬件按 **256** 封顶；`root_rd_addr` 只有 8 位，超出的值会被忽略而不是回绕）|
| 0x10 | MARKED | R | 标记对象数 |
| 0x14 | CYCLES | R | 硬件周期计数 |
| 0x18 | Q_HEAD | R | 队列头指针 |
| 0x1C | Q_TAIL | R | 队列尾指针 |
| 0x20 | STATUS | R | [0]=队列溢出（正常路径不可达：4096 对象 = 队列深度）[1]=AXI 读错误 [2]=引用失步 [3]=坏对象头（`ref_count>4096`）[4]=引擎 idle（`state==S_IDLE`）[5]=free-list 扫描 busy；除 [1] 按 start 清零外，其余每次 start 清零 |
| 0x24 | BM_ADDR | R/W | 位图探针地址（0~4095，只在引擎空闲时有效） |
| 0x28 | BM_DATA | R | 位图探测数据 = `mem[BM_ADDR]`（**2 拍**：BRAM 1 拍 + 探针寄存器 1 拍；两次读数之间不要改 BM_ADDR）|
| 0x30 | MAGIC | R | 固定 `0x47434343`（"GCCC"）：软件可比对，确认 bitstream 与驱动配对 |
| 0x34 | VERSION | R | 固定 `0x0004_0200`（v4.2，Phase 3A dirty set）|
| 0x38 | FREE_COUNT | R | 未标记对象数；mark `done` 后扫描位图得到（扫描期间 STATUS[5]=1）|
| 0x3C | FREE_DATA | R | 读一次弹出一个 free 对象 ID；先读 FREE_COUNT，再读 count 次 |
| 0x40+ | ROOT_LIST | W | 根集对象 ID 数组（0x40~0x43F，最多 256 个） |
| 0x440 | DIRTY_PUSH | W/R | **W**：`(tag<<12) \| id` —— **带标签命令**：标签（`[15:12]`）必须每次逻辑推送都变化；本板 AXI-Lite 写路径把每次 store **投递两遍**（探针实测，任意位宽），标签不变即视为重复投递被忽略。**R**：当前 FIFO 占用（0~256）|
| 0x444 | DIRTY_STAT | R | [8:0]=占用 [9]=溢出（粘滞；满 256 丢弃并置位）[10]=仍有待处理 [19:16]=上次接受的标签、[31:20]=最后被接受的 id（AGENTS #20 的 id 级回执：`dirty_push_acked()` 用 tag+id 双重比对确认每条推送真的进了 FIFO；只读追加，`VERSION` 不变）|
| 0x448 | DIRTY_DRAINED | R | 本 epoch 引擎已消费条数（每次 `start` 清零）|
| 0x44C | DIRTY_PUSHED | R | 自上次 flush 以来被接受的条数（可与 drained/popped 对比）|
| 0x450 | DIRTY_POPPED | R | 自上次 flush 以来被 pop 的条数 |

> `DIRTY_PUSH` 用 `0x440`：根表写到 `0x43F` 为止，寄存器从 `0x440` 起。

### Phase 3A/3B：脏边驱动与增量标记（摘要）

`gc_dirty_fifo` 给标记引擎加了一条「屏障记录」输入（写 `0x440`，值 `(tag<<12) | id`）：
位图未标 → 置位并计数；**已标 → 强制重扫（不重复计数）**；`S_DONE` 额外要求 FIFO 为空；
满 256 丢弃并置粘滞溢出位——软件见溢出必须退回**全标记**。
epoch 三步：**全标记**（`CTRL[5]` flush）→ **增量步**（`CTRL=0x11`，不 flush，mutator 可并发推送）
→ **remark 收口**（再一个增量 epoch）。
屏障契约：**先让指针存储对 PL 可见，再写 `0x440`**；推送带 changing tag 去重（本板 store 会重投递且不保证相邻）。

协议全文、屏障契约、并发证明、溢出/防护与软件接口见
[`docs/design-details.md`](docs/design-details.md)。板上证据：`tests/dirty_set_test.py`、
`dirty_concurrent_test.py`、`dirty_overflow_test.py`、`dirty_leftover_test.py`、`dirty_api_test.py`、`ctrl_spill_test.py`。

### 关键设计参数

| 参数 | 值 | 说明 |
| --- | --- | --- |
| `MAXO` | **8** | 未完成读事务上限，与 PS7 `S_AXI_HP0` 自己声明的 `NUM_READ_OUTSTANDING=8` 一致；再大只会被 `ARREADY` 反压 |
| `QD` | **80** | 每条流的命令/数据 FIFO 容量（存储体 128 深、指针 7 位） |
| `PD` | **4** | 对象头暂存环深度 = **预取深度**（领先最多 4 个对象） |
| `DQD` | **8** | 引用描述符队列深度（对象头填好即入队，由 issuer 独立发命令） |
| 对象上限 | **4096** | 12 位对象 ID / 位图 4096×32 / 队列 4096 深 |
| AXI 协议 | **AXI3** | Zynq-7000 HP 口原生协议：`ID_WIDTH=6`、单拍、`ARSIZE=3`(8 字节) |
| 流 ID | **0 = 引用, 1 = 对象头** | 两流各有独立数据 FIFO；同 ID 保序、异 ID 互不阻塞 |
| 时钟 | **FCLK0 = 100MHz** | 引擎 / AXI-Lite / AXI HP 同一域，**无 CDC** |
| 位图 | 4096×32 = 128 Kb | 对象 x 的状态 = `mem[x]` 的第 `x%32` 位 |
| 队列 | 4096×12 = 48 Kb | 带 `count` 判空/满 |
| FSM 编码 | 5 位 / 25 个 | 12 个在用，13 个保留（未删除）|

> AXI 读流水线的清理语义（`run_start`/`abort` 清两条 FIFO、逐拍丢弃在途响应）见
> [`docs/design-details.md`](docs/design-details.md)。

### Object Graph DDR Format

```
@ obj_base + k*16:                @ ref_addr:
┌──────────────────────┐          ┌──────────────────────────┐
│ +0:  uint32 obj_id   │          │ [ref0][ref1]...[0xFFFF]  │
│ +4:  uint32 ref_count│          │                          │
│ +8:  uint32 ref_addr │──────────┘                          │
│ +12: uint32 reserved │          └──────────────────────────┘
└──────────────────────┘
```

引擎通过两步读取引用：
1. 读对象头 `+4` → `ref_count`
2. 读对象头 `+8` → `ref_addr` (引用数组物理地址)
3. 从 `ref_addr + j*4` 读取第 j 个引用

### 中断链路（仅作为验证测试使用）

`gc_top.irq_o = done` 接到 `ps7_0/IRQ_F2P[0]`，即 **GIC 中断 ID 61**（`ISPENDR1` bit 29）。
最小内核模块的用法、实测结果与两处约束见 [`docs/design-details.md`](docs/design-details.md)；
证据 `tools/logs/board_irq.log`。

## 4. 正确性、性能与测量

### 三方对比（FPGA / C 未缓存 / Python 脚本）
`test_main` 的 Test 1 在**同样的对象数、同样的 avg_refs=3** 下，把 FPGA 标记与**同一套 BFS 的 C 实现**
（`fpga_gc_sw_mark`）对比；C 同时是 `marked` 的独立 oracle。表里时间的口径见下方「测量口径」。
实测（XC7Z100，PL 100 MHz，**位流 md5 `3D3A9F1D…` / BOOT sha256 `63e52587…`**，
2026-10-24，`tools/logs/board_test_main.log`）：

```
Objects  marked   FPGA us   C us      vs C
10       9        44.2      13.8      0.3x
50       47       48.7      29.7      0.6x
100      96       57.0      58.2      1.0x
500      474      113.5     261.9     2.3x
1000     945      184.4     519.9     2.8x
2000     1882     339.9     1056.9    3.1x
4000     3766     646.2     2159.6    3.3x
```

- `vs C`：FPGA 与 C 的比值，>1× 表示 FPGA 更快。
- 小图（<100 对象）FPGA 更慢：固定启动开销约 4400 拍。`marked < Objects` 是随机图中从根 0 不可达的对象。

### 测量口径

口径与证据边界见 [`docs/measurement.md`](docs/measurement.md)：`FPGA us` 只含引擎时间；
`C us` 是未缓存 DDR 口径（与引擎同阶段）；cache 命中时 C 会更快，**必须一起报**。

### 版本对比与优化手段（历史）

Ver1–Ver4 的每对象周期从 90.2 降到 15.4，四步优化（多笔未完成读 / 对象头预取 / 逐引用快路径 / 引用流水）
的效果与附带改动见 [`docs/performance-history.md`](docs/performance-history.md)（`historical/unverified`）。

### 对优化 C 的参考对比

板上带一个独立的 C 基准 `cmark`（交叉编译的 ARM 动态链接二进制，`run_cmark.sh` 一键跑）：
在**同一张图**上同时跑硬件和 C 两遍，三个实现的标记数必须都等于已知真值 L。

**实测（72 次；4 组参数）**：每对象 HW 17.5–20.6 拍，72 次全部 OK。

| 组 | maxN / trials / avg_refs | HW 拍/对象 | C-uncached | C-cached | **HW / C-unc** | **HW / C-cac** |
| -- | ------------------------ | ---------- | ---------- | -------- | -------------- | -------------- |
| 1  | 4096 / 24 / 2            | 17.5       | 560 ns     | 168 ns   | **3.2x**       | **1.0x**       |
| 2  | 4096 / 16 / 4            | 20.2       | 678 ns     | 183 ns   | **3.4x**       | **0.9x**       |
| 3  | 4096 / 16 / 1            | 17.7       | 491 ns     | 136 ns   | **2.8x**       | **0.8x**       |
| 4  | 2048 / 16 / 2            | 20.6       | 550 ns     | 130 ns   | **2.7x**       | **0.6x**       |

72 次全部 OK；三个实现（HW / C 非缓存 / C 缓存）标记数均等于真值 L。

> 上表用**位流** `3D3A9F1D…`（2026-10-24，`tools/logs/cmark_sweep.log`）跑满 72/72 OK；
> C 侧波动 ±3%。命令：`tools/tests/run_cmark_sweep.ps1`。

**结论**：

- 对同样走非缓存 DDR 的 C 标记，硬件快 **2.6~3.4x**
- 对数据已驻留 CPU cache 的进程内 C 标记，硬件 **0.6~1.0x**（大多数参数略慢，avg_refs=2 时最接近）
- avg_refs 越大硬件越占优（**3.4x**）

#### 适用条件

| 图所在位置 | CPU 每次依赖读 | 硬件（AXI HP，非一致）|
|---|---|---|
| DDR（非缓存）| 一次 DDR 往返，无重叠 | 同样往返，8 笔未完成读 + 对象头预取 |
| CPU cache | L1/L2 命中，几纳秒 | 仍走 AXI HP 到 DDR |

硬件只在指针追逐被 DDR 延迟钉住时占优（**2.6–3.4×**）；图驻留 CPU cache 时为 **0.6–1.0×**。
硬件另有固定开销（配置、清队列、清 4096 位图、drain），小图摊不薄。

> 同阶段对比见主表（C 未缓存 BFS）；`cmark` 是 C 侧参照（含 cache 驻留），`py_bfs.py` 是
> Python 字节码 BFS 的量级参照。

### 端到端成本

`FPGA us` 只含引擎时间；板上实测中构图（Python）主导：构图 **197.7 ms/图**（`board_gc_test.log` 的 "build 197.7 ms avg"）、
硬件标记 **0.320 ms/图** ⇒ **618×**。明细、口径与原始日志见 [`docs/measurement.md`](docs/measurement.md)。

### 仿真回归

`sim\run_sim.bat`（或 `sim/run_sim.sh`）**只跑 `tb_gc_top`**：主用例 + T1–T8 + T-FREE + T-DIRTY +
T-DIRTY-TAG/RACE + T-ABORT/T-ABORT2 + T-MAXFAN/T-ROOTCLAMP/T-STAR + AXI 协议检查；
定向回归另有 `tb_axi_read` / `tb_runstart_race` / `tb_cmdfifo_flush` / `tb_regs_aww`，`tools\reproduce_all.ps1` 串起五组 xsim。
完整用例矩阵与反向验证见 [`docs/simulation.md`](docs/simulation.md)。

## 5. 发布与上板

> 本仓库根目录即为完整工程；`artifacts/` + `tools/` 是上板验证所需的一站式内容。

### 下载启动镜像（Release）

`image.ub` 为 **43.2 MB**，不入仓库：二进制镜像随 Release 发布，
仓库只保留可复现的构建配置。
`BOOT.BIN` **不入库**（厂商 FSBL + U-Boot 无可 MIT 再分发，见 `NOTICE`），只在 GitHub Release 提供。

> ⚠️ 下表是 **GitHub Release 资产**的哈希。仓库与 tag **都不跟踪** `BOOT.BIN`（`artifacts/BOOT.BIN` 被 `.gitignore` 排除），
> 所以 tag 树里根本没有这个文件，不要试图用 tag 树核对哈希。
> 阶段 2/3 的变更与板级结果见「正确性、性能与测量」与 `AGENTS.md`；证据边界见本文顶部。

| 资产 | 烧录位置 | 大小 | SHA256 |
| --- | --- | --- | --- |
| `BOOT.BIN` | BOOT 分区根目录 | 18,582,724 B | `63e525870584f3eb9cced20c0c6626ec286ca46cc68f3992c6d232a6fb661a71` |
| `image.ub` | BOOT 分区根目录 | 43,295,771 B | `5b66851fdbfa44bca96f5ad7b7c881acbac2d993ca3e2211766a6cb05d887644` |
| `card-boot.zip` | 解压到 BOOT 分区根目录 | 5,952 B | `9e555af07027789080487247247bc55d942febd4e324ce5b6ba44340edbba642` |
| `card-userdata.zip` | 解压到 USERDATA 分区根目录 | 94,173 B | `17c47aed386aa3907946af3825a1a64a5be1475729545a0dedac2f1189658c16` |

> 以上由 `tools/make_release_zips.ps1` + `tools/make_release_manifest.ps1` 生成；`BOOT.BIN` 是
> hand-over 修复（AGENTS #21）后重打的镜像；该镜像的上电复测结果见 `tools/logs/README.md` 的日志索引。卡包只含运行所需脚本与二进制，
> 不含任何解释器基准脚本。
>
> **语义变更（`VERSION` 仍是 `0x0004_0200`）**：`CTRL[5]=DIRTY_FLUSH` 自 2026-10-23 起是 **arm-and-consume**
> ——写只“武装”，在下一次 `BM_KEEP=0` 的 `START` 才生效，被增量 `START` 丢弃；`DIRTY_STAT[31:20]` 同时新增
> “最后被接受的 id”。按旧语义（写 `CTRL[5]` 立即清空 FIFO）写的驱动必须改成“先写 flush、再写 `START`”；
> 需要逐条确认的调用者用 `dirty_push_acked()`（tag+id 回执）或 `barrier_verify()`（按效果验收）。

校验：`sha256sum -c artifacts/SHA256SUMS.release`（四个资产放在同一目录）。

> **烧录步骤**（两个 FAT32 分区，卷标分别 `BOOT` / `USERDATA`）：

1. BOOT 分区：放 `BOOT.BIN`、`image.ub`，再解压 `card-boot.zip`（`boot.scr` / `uEnv.txt` / `mount_data.sh` / `system.dtb`）
2. USERDATA 分区：解压 `card-userdata.zip`（`run_*.sh` / `gc_test.py` / `cmark` / `bin/test_main` / `py/` / `tests/` / `ko/`）
3. 插卡上电；登录后在 USERDATA 里 `sh run_gc.sh 4096 8 2` 自检

> `card-userdata.zip` 里的 `ko/fogccc-irq.ko` 与本镜像的内核严格配对
> （`vermagic=6.18.10-xilinx-g4f7afe14f724`）；换内核就要重新 build 模块。
>
> **历史版本**：`v1-original` 的 Release、标签和 RTL 存档都已移除（原型机内容不再发布）；
> Ver1 的性能数据仍保留在上面的性能表里。v3 的启动镜像同样不提供，只保留 `v3-optimized` 标签和数据。

### TF 卡布局

| 分区 | 类型 | 卷标 | 内容 |
|---|---|---|---|
| p1 | FAT32 | (BOOT) | `BOOT.BIN` / `image.ub` / `boot.scr` / **`uEnv.txt`** / `mount_data.sh` |
| p2 | FAT32 | **USERDATA** | `run_gc.sh` / `run_cmark.sh` / `run_repeat.sh` / `gc_test.py` / `cmark` + `bin/` `tests/` `py/` `ko/` `logs/` |

> ⚠️ `USERDATA` 必须是 **FAT32**：板子内核没有编 exFAT (`# CONFIG_EXFAT_FS is not set`)。
> Windows 图形界面无法创建 >32GB 的 FAT32，用板子自己格式化：
> `mkfs.vfat -F 32 -n USERDATA /dev/mmcblk0p2`

### 上板流程

```
① 双击 tools/fogccc.bat
② 板子上电
   出现 linux login:
③ root + 回车 → 空密码（`CONFIG_imagefeature-empty-root-password=y`）
④ 数据分区 p2 由 udev 开机挂在 /run/media/USERDATA-mmcblk0p2（stock /etc/fstab 里没有 p2 条目）；
   /mnt/userdata 要自己挂：sh /mnt/boot/mount_data.sh（主机脚本也会 mkdir+mount）。两条路径是同一个分区。
⑤ sh /run/media/USERDATA-mmcblk0p2/run_gc.sh   # 若已挂到 /mnt/userdata 就用那条路径
```

测试输出同时打印到窗口并写入 `USERDATA` 分区上的 `gc_run_<时间戳>.log`。

### Windows 快捷指令与板上测试速查

串口工具与 `serial_*.ps1` 用法、板上各条测试命令、结果判读与常见问题见
[`docs/board-usage.md`](docs/board-usage.md)。

## 6. 调试与监控

| 数据 | 位置 | 查看方式 |
|------|------|---------|
| 标记结果 | 寄存器 0x10 | C 程序读取并打印 |
| 硬件周期 | 寄存器 0x14 | C 程序读取并打印 |
| 队列状态 | 寄存器 0x18/0x1C | C 程序读取 |
| 对象图 | DDR @ 0x1E000000 | C 程序通过 /dev/mem 访问 |
| 内部信号 | FPGA 内部 | Vivado ILA 在线调试 |

### ILA 在线调试

在 `build.tcl` 中添加 ILA IP 可观测内部信号:
```tcl
create_bd_cell -type ip -vlnv xilinx.com:ip:system_ila:1.1 ila_0
# 探测: state, cur_obj, marked_r, bm_addr, bm_rdata, q_push 等
```

## 7. License

MIT（见 `LICENSE`）。例外与第三方组件见 [`NOTICE`](NOTICE)。

- `driver/fogccc_irq.c`、`driver/plnx/fogccc-irq/files/fogccc-irq.c`：GPL-2.0（文件首行 SPDX 标识）。
- `BOOT.BIN` / `image.ub` 由 `petalinux/build_fogccc2.sh` **打包生成**；其中 `zynq_fsbl.elf` 是**输入**
  （厂商 FSBL，授权原因不入库、也不随 Release 发布，仅本机 `artifacts/` 保留），`image.ub` 由 PetaLinux 构建。
- `system.dtb` 也不入库；`boot.scr` / `uEnv.txt` / `mount_data.sh` 入库（都是文本，随 Release 的 `card-boot.zip` 一起发）。
- 仓库不含 AMD 源码或文档；`vivado/build.tcl` 仅含 IP 配置参数。

---
