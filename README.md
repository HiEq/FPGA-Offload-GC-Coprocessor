# FPGA Offload GC Coprocessor（FOGC²）

[![Platform](https://img.shields.io/badge/Platform-Xilinx%20Zynq--7000%20XC7Z100-blue)](#platform)
[![RTL](https://img.shields.io/badge/RTL-Verilog%202001-green)](#3-设计与接口)
[![Vivado](https://img.shields.io/badge/Vivado-2026.1-orange)](#2-快速开始)
[![License](https://img.shields.io/badge/License-MIT-yellow)](#7-license)
[![CI](https://github.com/HiEq/FPGA-Offload-GC-Coprocessor/actions/workflows/lint.yml/badge.svg)](https://github.com/HiEq/FPGA-Offload-GC-Coprocessor/actions/workflows/lint.yml)

> `CI` 进行静态检查与定向回归：shell/Python/PowerShell 语法、`iverilog` RTL 解析、
> `gcc -fsyntax-only`、`SHA256SUMS`，以及 `tb_runstart_race` / `tb_cmdfifo_flush`
> 两个定向测试。
> **CI 不进行 Vivado 综合/实现、xsim、PetaLinux 或上板**。功能证据见「仿真回归」「板上测试命令速查」与 `tools/logs/`。
>
> **P1 证据边界（2026-10-21）**：
> ① `board_*_p1_20261021.txt` 是命令输出与哈希头，**不是完整冷启动串口 transcript**；
> ② `3590FBB5` 未重新运行 `cmark` / `benchmark.py`，C 基线与 CPython 梯度来自 `02D52FCC`；
> ③ 当前 P1 证据没有对应的 Vivado 综合/实现、xsim、PetaLinux 重构建记录。

Contents: [项目与平台](#1-项目与平台) · [快速开始](#2-快速开始) · [设计与接口](#3-设计与接口) ·
[正确性、性能与测量](#4-正确性性能与测量) · [发布与上板](#5-发布与上板) ·
[调试](#6-调试与监控) · [License](#7-license)

把 GC 的**标记阶段**卸载到 Zynq-7000 PL：BFS 指针追逐由硬件完成，对象图放在DDR内。

| 对比对象 | 规模 | 时间 | 与各项对比 |
|---|---|---|---|
| **FPGA 标记**（`cmark`，bitstream `02D52FCC`）| 4096 对象 | **0.72 ms** | — |
| **FPGA 标记**（`test_main`，bitstream `3590FBB5`）| 4000 对象 | **0.644 ms** | — |
| C，逐条读 DDR（数据不在 cache）| 4096 对象 | 2.3 ms | **3.2×** |
| C，数据在 cache | 4096 对象 | 0.63 ms | 0.9× |
| CPython `gc.collect()`（整堆，含清扫）| 4000 对象 | 17.66 ms | **27×** |
| Python 脚本 BFS（逐条读 `/dev/mem`）| 同图 | — | **199–251×** |

> `27×` = 17.66 ms ÷ 0.644 ms（同一张 4000 对象图，P1 `test_main`）；`0.72 ms` 是 `cmark` 的
> 4096 对象，不与 17.66 ms 相除。`FPGA` 一列只有引擎周期（`CYCLES / 100 MHz`）；
> 完整口径、旧证据标注与端到端成本见「正确性、性能与测量」。
>
> **实现范围**：stop-the-world，写 `START`、轮询 `DONE`；对象图由 `csrc/fpga_gc.c` /
> `python/fogccc.py` 按「对象头 + 引用数组」布局构造，**未接入** CPython 的 `gc` 模块与 `PyObject` 布局。

## 1. 项目与平台

### 架构概览

```
┌─────────────────────────────────────────────────────────────┐
│                    Zynq-7000 XC7Z100                        │
│  ┌──────────────────────┐     ┌──────────────────────────┐  │
│  │   PS (ARM Cortex-A9) │     │   PL (FPGA Fabric)       │  │
│  │                      │     │                          │  │
│  │  CPython Runtime     │     │  ┌────────────────────┐  │  │
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

#### 工作流程

1. ARM PS 上的 CPython 运行程序，触发 GC
2. C 驱动通过 `/dev/mem` 将对象图写入 DDR (`0x1E000000`)
3. C 驱动写 AXI-Lite 寄存器启动 FPGA 标记引擎
4. FPGA 引擎执行 BFS 标记
5. ARM PS 轮询完成标志，读取标记结果和周期计数
6. CPython 据此跳过/回收未标记对象

> **当前实现**：第 1、6 步是目标形态，CPython 的 `gc` 模块尚未接入。
> 对象图由 `csrc/fpga_gc.c` / `python/fogccc.py` 按「对象头 + 引用数组」布局构造；
> 标记语义与 GC 的 mark 阶段一致，回收动作由 CPython 完成。

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
| 实测资源占用 | LUT 7,600 (2.74%) ／ FF 18,215 (3.28%) ／ BRAM 5.5 (0.73%) ／ DSP 0 |
| 时序 | WNS +1.435 ns ／ WHS +0.046 ns                                    |
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
│   ├── test_main.c         测试主程序 (4 项，含 FPGA/C/CPython 三方对比)
│   ├── py_bfs.py          Python BFS 参照（独立 oracle；test_main 调的是 gc_probe.py）
│   ├── cmark.c             C 基准源码（卡上二进制在 artifacts/userdata/cmark）
│   └── build_cmark.sh      cmark 交叉编译
├── python/                 ctypes 绑定 + CPython 基准（gc_probe.py / benchmark.py）
├── vivado/
│   ├── build.tcl           BD + 综合 + 实现 + XSA
│   └── build_rtl_only.tcl  复用 BD
├── tools/                  宿主脚本
│   ├── serial_run_gc.ps1 / serial_push_chunked.ps1 / make_manifest.ps1 / make_card.ps1
│   ├── reproduce_all.ps1    宿主侧一键复现（manifest + PS 单测 + 四组 xsim）
│   ├── tests/(功能测试)  debug/(调试工具)
│   └── logs/               证据日志（只留 README 引用的那些，见其中的 README.md）
├── driver/                 内核中断驱动 + PetaLinux 模块 recipe
├── petalinux/              工程骨架 (config/rootfs_config/meta-user) + 命令构建
├── artifacts/              要拷到 TF 卡的构建产物 + SHA256SUMS（二进制清单）
├── .github/workflows/      CI: lint + iverilog 定向回归 + gcc + SHA256SUMS 校验
├── AGENTS.md               本项目对 AI 参与者的工程约束
├── petalinux/BUILD_GUIDE.md 构建步骤
└── README.md               本文件
```

## 2. 快速开始

> 串口脚本自动识别 CH340；如果需要指定COM口可加 `-Port COMx`。
> 完整清单见「Windows 侧快捷指令」。

### 1. 生成比特流 (PC 端)

```powershell
cd <repo>/vivado
vivado -mode batch -source build.tcl
```

产出: `fogccc_proj\fogccc_z7100.runs\impl_1\system_wrapper.bit`

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
cd /mnt/userdata                        # /etc/fstab 开机自动挂载；旧镜像可能用 /run/media/USERDATA-mmcblk0p2
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
cd /mnt/userdata/py
python3 fogccc.py        # 三方对账：FPGA / C / 位图读回 + STATUS
```

### 5. 软件基准 (任意 Linux)

```bash
python3 python/benchmark.py
```

## 3. 设计与接口

### Register Map

| 偏移 | 名称 | R/W | 说明 |
|------|------|-----|------|
| 0x00 | CTRL | R/W | [0]=start [1]=**保留**（旧 clear_bm，位图由引擎每轮自动清） [2]=clear_q [3]=abort（把引擎拉回 IDLE、清 DONE、清 BFS 队列与读流水线；仿真 `T-ABORT`/`T-ABORT2` 红→绿 + 板上 `abort_test.py` T1–T5 与 `abort_sweep.py` 11 个相位，`STATUS` 保持 0；驱动超时路径会写它） [31]=done |
| 0x04 | OBJ_BASE | R/W | 对象图 DDR 物理地址 |
| 0x08 | OBJ_COUNT | R/W | 对象总数 (最大 4096) |
| 0x0C | ROOT_COUNT | R/W | 根集数量（硬件按 **256** 封顶；`root_rd_addr` 只有 8 位，超出的值会被忽略而不是回绕）|
| 0x10 | MARKED | R | 标记对象数 |
| 0x14 | CYCLES | R | 硬件周期计数 |
| 0x18 | Q_HEAD | R | 队列头指针 |
| 0x1C | Q_TAIL | R | 队列尾指针 |
| 0x20 | STATUS | R | [0]=队列溢出（正常路径不可达：4096 对象 = 队列深度）[1]=AXI 读错误 [2]=引用失步 [3]=坏对象头（`ref_count>4096`）[4]=引擎 idle（`state==S_IDLE`）；除 [1] 按 start 清零外，其余每次 start 清零 |
| 0x24 | BM_ADDR | R/W | 位图探针地址（0~4095，只在引擎空闲时有效） |
| 0x28 | BM_DATA | R | 位图探测数据 = `mem[BM_ADDR]`（**2 拍**：BRAM 1 拍 + 探针寄存器 1 拍；两次读数之间不要改 BM_ADDR）|
| 0x30 | MAGIC | R | 固定 `0x47434343`（"GCCC"）：软件可比对，确认 bitstream 与驱动配对 |
| 0x34 | VERSION | R | 固定 `0x0004_0000`（v4.0）|
| 0x40+ | ROOT_LIST | W | 根集对象 ID 数组（0x40~0x43F，最多 256 个） |

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

> `gc_axi_read` 在 `run_start` 时清空命令 FIFO 与数据 FIFO，
> 并逐拍丢弃在途响应，直到两条流的在途计数归零才发新命令。
> 覆盖：`done_race_test.py` P3（每轮 `STATUS[3:0]=0` 且 `[4]=1`；修复前为 `0x4`，并有一次标出 964/768）。

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

`gc_top.irq_o = done` 接到 `ps7_0/IRQ_F2P[0]`，即 **GIC 中断 ID 61**
（`ISPENDR1` bit 29）。`driver/` 里有一个最小模块验证整条链路：

```
insmod fogccc-irq.ko          # 映射 SPI 61 + request_irq，生成 /dev/fogccc_irq
echo arm > /dev/fogccc_irq    # 使能（done=0 时不会触发）
python3 gc_test.py 1024 1 2 --seed 11   # done 0 -> 1
cat /dev/fogccc_irq           # "1 0 <virq>"  ← 中断已触发，处理函数自动关线
```

实测（发布镜像，PL 刚配置）：`before arm 0 0 / after arm 0 1 / after run 1 0`，`VERDICT: IRQ_DRIVEN_DONE_OK`
（`tools/logs/board_irq_20261020.txt`）。前提是 PL 处于 `done=0`；若 `done=1`（跑过一次），插模块就会先计一次中断，测试会报 FAIL。
两处约束见 `driver/README.md`（hierarchy 域没有 `.map`；`fwspec.param[1]` 是
SPI 编号 = ID − 32）。

## 4. 正确性、性能与测量

### 三方对比（FPGA / C / CPython）
`test_main` 会用 `popen` 调用 `tests/gc_probe.py`，在**同样的对象数、同样的 avg_refs=3** 下运行 CPython
`gc.collect()`（三次取最快）。默认路径是 `/mnt/userdata/tests/gc_probe.py`；
如果分区在 `/run/media/USERDATA-mmcblk0p2`，程序会自动改用备用路径，也支持显式传参。
表里三个时间的口径见下方「测量口径」。实测（XC7Z100，PL 100 MHz，
**P1 修复镜像：bitstream `3590FBB5…` / BOOT `7487463a…`**，2026-10-21，`tools/logs/board_test_main_p1_20261021.txt`）：

```
Objects  marked   FPGA us   C us      CPython ms   vs C    vs CPython(整堆)   CPython 增量 us/个   vs CPython(增量)
10       9        44.0      14.0      7.198        0.3x    164x              —                    —
50       47       48.7      30.1      7.375        0.6x    151x              4.43                 4.3x
100      96       58.7      58.3      7.481        1.0x    127x              3.14                 5.1x
500      474      113.8     261.5     8.320        2.3x    73x               2.29                 9.5x
1000     945      185.0     514.9     9.610        2.8x    52x               2.44                 12.4x
2000     1882     339.4     1132.0    12.176       3.3x    36x               2.50                 13.9x
4000     3766     644.0     2202.5    17.662       3.4x    27x               2.62                 15.3x
```

- `vs CPython(整堆)`：一次完整回收 vs 一次标记，含解释器堆的固定成本。
- `CPython 增量 us/个` = `(CPython ms − 7.198) × 1000 / (n − 10)`：多这 n−10 个对象的边际成本。
- `vs CPython(增量)` = `CPython 增量 us/个` ÷ `(FPGA us / marked)`：每对象口径。

小图（<100 对象）FPGA 更慢：固定启动开销约 4400 拍。`marked < Objects` 是随机图中从根 0
不可达的对象。

### 测量口径

- `FPGA us` = `CYCLES` / 100 MHz：**只含引擎时间**，不含构图/写对象头/清队列轮询/驱动 `usleep`。
- `C us`：同一张图、同一套 BFS 的 C 实现，与 FPGA 同阶段，可比。
- `CPython ms`：`test_main` 经 `popen` 调用 `tests/gc_probe.py`，在同样对象数下做三次完整
  `gc.collect()` 取最快 —— 是整个解释器堆的回收（mark+sweep），**只能当上界**。
- **同规模对比以主表为准**（4000 对象 **27×**）；`gc.collect()` 含清扫、硬件只做标记。
- `python/benchmark.py` 是同一口径的批量版（10–4000 对象梯度）；其归档输出与 `cmark_sweep.log` 属于旧 `02D52FCC` 证据，P1 `3590FBB5` 未重跑 `cmark` / `benchmark.py`。
- `py_bfs.py` 是独立 oracle；P1 为 **199–251×**，旧 `81640C7C` / `074CF12D` 为 **225–278×**，不要和 CPython 的 27× 混用。
- 当前 P1 原始记录：`tools/logs/board_test_main_p1_20261021.txt`、`tools/logs/board_gc_test_p1_20261021.txt`；旧 `81640C7C` 证据仅作历史对照。

### 版本对比（历史数据）

历史版本 Ver1–Ver4 的对照表，用于说明每步优化的效果；P1 当前镜像的可复核数据见「三方对比」。
旧 `81640C7C` / boot `074CF12D`（冷启动 `6874fb55…`）只作历史对照，**下表没有对应的归档日志（`historical/unverified`）**。
"每对象周期" = HW cycles ÷ 活跃对象数（已扣除固定的 4096 拍清位图）。

> **可复现**：`gc_test.py` 支持 `--seed N` 并会把种子打印在日志里
> （不传则从时钟取一个并打印），同一种子的两次运行图**完全一致**。
> P1 本次 8 轮的种子是 `1419464340`（`--seed 1419464340` 可重放）。
> 同一张图重复跑 100 次（`test_main` Test 3），P1 cycles 在 18406–18517 之间，极差 0.6%。

|                | 原始设计 Ver1<br>(单笔未完成读) | Ver2<br>(多笔未完成读 + 快路径) | Ver3<br>(+ 对象头预取 + 竞态修复) | Ver4 [H]<br>(+ 引用流水 + 6 项修复) |
| -------------- | ------------------------------- | ------------------------------- | --------------------------------- | ------------------------------- |
| 判定           | 8/8                             | 8/8                             | 8/8                           | 8/8                         |
| 总 HW cycles   | 1,804,791                       | 557,091                         | 484,034                       | 240,007 [H]                     |
| 活跃对象合计   | ~20,010                         | 14,441                          | 12,449                            | 13,497                          |
| 每对象周期     | 90.2                        | 38.6                            | 38.9         | 15.4            |
| vs `py_bfs`（脚本）| 37.5~39.5x                      | 100~126x                        | 104~123x                      | 220.8~279.3x                |
| N 范围         | 541~3895                        | 529~4048                        | 639~3872                          | 816~3840                        |

> 各列来自不同的随机图（见"活跃对象合计"行），只有**每对象周期**可比。
> 本表是历史数据（`historical/unverified`）；P1 当前镜像可复核的 8/8 见
> `tools/logs/board_gc_test_p1_20261021.txt`（184,767 拍）。旧 `81640C7C` 的 218,429 拍只作历史对照。

### 提升幅度

```
每对象周期    90.2 → 15.4          = 5.9x     (Ver1 → Ver4, run_gc)
             38.3 → 17.5          = 2.19x    (Ver3 → Ver4, cmark 同一张图, 最严格)
总 HW cycles  1,804,791 → 484,034  = −73%     (Ver1 → Ver3)
```

**数据出处**：命令与历史基线见上方「版本对比」；比特流/BOOT 为历史记录，归档日志里查不到对应哈希（`historical/unverified`）。


### 优化手段（四步）

| # | 手段 | 效果 |
|---|---|---|
| 1 | **多笔未完成读**：`gc_axi_read` 改成"命令 FIFO + 数据 FIFO"的读命令队列，引擎可连续压入地址互不依赖的读 | 每个对象从 `2 + ref_count` 次**串行**往返 → 2 次**并发**往返 |
| 2 | **引用阶段压入/取回交错** + **对象头投机预取**：引用命令边压边收；当前对象引用命令压完后立刻从队列弹下一个对象、把它的两笔头读也压进去 | 下一个对象的头延迟被完全覆盖 → 每个对象只暴露 **1 次往返**；无 `REF_MAX` 截断 |
| 3 | **逐引用快路径**：位图改成读写地址独立的简单双口 BRAM；取到引用值那一拍就发读地址，下一拍"判定+置位+入队"一拍完成 | 每次引用 6 拍 → **2 拍** |
| 4 | **引用流水**：把"发引用读命令"从主状态机剥离成独立 issuer，描述符在**对象头填好的那一刻**就入队，最多领先 4 个对象；对象头改走**独立的 AXI 流**（`ID=1`），与引用流（`ID=0`）互不阻塞 | 引用读延迟被后续对象的处理盖住：LAT 扫描斜率 **1.00 → 0.71**；每对象 **38.3 → 17.5 拍** |

配套：AXI HP 从 FCLK1 (200MHz) 挪到 FCLK0 (100MHz)，省掉 2FF CDC 同步器。

### 对优化 C 的参考对比

板上带一个独立的 C 基准 `cmark`（交叉编译的 ARM 动态链接二进制，`run_cmark.sh` 一键跑）：
在**同一张图**上同时跑硬件和 C 两遍，三个实现的标记数必须都等于已知真值 L。

**实测（72 次；4 组参数）**：每对象 HW 17.5~20.6 拍，72 次全部 OK。

| 组 | maxN / trials / avg_refs | HW 拍/对象 | C-uncached | C-cached | **HW / C-unc** | **HW / C-cac** |
| -- | ------------------------ | ---------- | ---------- | -------- | -------------- | -------------- |
| 1  | 4096 / 24 / 2            | 17.5       | 557 ns     | 154 ns   | **3.2x**       | **0.9x**       |
| 2  | 4096 / 16 / 4            | 20.2       | 683 ns     | 168 ns   | **3.4x**       | **0.8x**       |
| 3  | 4096 / 16 / 1            | 17.7       | 488 ns     | 127 ns   | **2.8x**       | **0.7x**       |
| 4  | 2048 / 16 / 2            | 20.6       | 548 ns     | 127 ns   | **2.7x**       | **0.6x**       |

72 次全部 OK；三个实现（HW / C 非缓存 / C 缓存）标记数均等于真值 L。

> 上表用 bitstream `02D52FCC…`（2026-10-20，`tools/logs/cmark_sweep.log`）与 `cmark`（23,256 B）重跑，
> 72/72 OK；C 侧波动 ±3%。命令：`tools/tests/run_cmark_sweep.ps1`；新 `3590FBB5` 未重跑 cmark。

**结论**：

- 对同样走非缓存 DDR 的 C 标记，硬件快 **2.7~3.4x**
- 对数据已驻留 CPU cache 的进程内 C 标记，硬件 **0.6~0.9x**
  （仍慢 1.1~1.7x）
- avg_refs 越大硬件越占优（**3.4x**）

#### 适用条件

| 图所在位置 | CPU 每次依赖读 | 硬件（AXI HP，非一致）|
|---|---|---|
| DDR（非缓存）| 一次 DDR 往返，无重叠 | 同样往返，8 笔未完成读 + 对象头预取 |
| CPU cache | L1/L2 命中，几纳秒 | 仍走 AXI HP 到 DDR |

硬件只在指针追逐被 DDR 延迟钉住时占优（**2.7–3.4×**）；图驻留 CPU cache 时为 **0.6–0.9×**。
硬件另有固定开销（配置、清队列、清 4096 位图、drain），小图摊不薄。

> 与 CPython 的对比见主表（`gc_probe.py` 的 `gc.collect()`）；`py_bfs.py` 是 Python 字节码
> BFS 的参照，`cmark` 是 C 侧参照。

### 端到端成本

`FPGA us` 只含引擎时间；构图、写 DDR、AXI-Lite 配置、清队列、轮询都不算。
`gc_test.py 4096 8 2` 在板上实测（2026-10-21，P1 镜像 bitstream `3590FBB5…` / BOOT `7487463a…`，`tools/logs/board_gc_test_p1_20261021.txt`）：

| 阶段 | 时间 |
| --- | --- |
| 构图 + 写 DDR（Python 3.12，含 1 MB memset 与引用数组）| **103.7 ms / 图平均**（51.5–216.8 ms）|
| 同图 Python BFS（oracle）| **53.5 ms / 图平均**（25.4–113.3 ms）|
| 硬件标记（引擎）| **0.231 ms / 图平均**（0.127–0.451 ms；N = 784–3523）|

单次卸载的端到端成本由构图主导：**449×** 标记时间（103.7 / 0.231，P1 日志）。
构图走 Python；C 侧的 `fpga_gc_build_graph()` 未单独计时，同样不计入 `FPGA us`。
旧 `81640C7C` / `074CF12D` 的 164.0 ms、0.273 ms、601× 只作历史对照。

### 仿真回归

`sim\run_sim.bat`（Windows）或 `sim/run_sim.sh`（Linux，需 `VIVADO_BIN`）**只跑 `tb_gc_top`**，
覆盖下面的主用例、T1–T8、T-ABORT/T-ABORT2、T-MAXFAN/T-ROOTCLAMP/T-STAR 和 AXI 协议检查。
定向回归要单独跑：

- `sim\run_axi_tb.bat` / `sim/run_axi_tb.sh` —— `tb_axi_read`（未完成读事务上限）
- `sim\run_race_tb.bat` / `sim/run_race_tb.sh` —— `tb_runstart_race`（同拍旧 R beat）
- `sim\run_cmdfifo_tb.bat` / `sim\run_cmdfifo_tb.sh` —— `tb_cmdfifo_flush`（同拍命令 FIFO）

`tools\reproduce_all.ps1` 串起 manifest、PS 单测和**四组 xsim**：
`tb_gc_top` / `tb_axi_read` / `tb_runstart_race` / `tb_cmdfifo_flush`。

| 检查 | 内容 |
| --- | --- |
| 主用例 | N=300 / 活跃 250 / 孤岛 50；标记数、队列尾、位图逐位比对 |
| STATUS | `0x20` 的错误位 [3:0] 必须为 0，且 [4]=1（引擎 idle）|
| **T1** | 连续两次运行：`marked` 两次都必须是 2 |
| **T2** | 重复根（同一 root 写两次）：只算一次 |
| **T3** | 流水 AW（AW/W 背靠背两笔写）：两笔都必须落到正确寄存器 |
| **T4** | 非法对象头（`ref_count=0xFFFFFFFF`）：被拒、`STATUS[3]=1`、`marked` 仍是活跃区 |
| **T5** | 12 位寄存器地址：`root[60]` 在 `0x130`；写地址截断到 8 位会标记 0 个对象 |
| **T6** | **位图探针**：`0x24/0x28` 读回必须与 BRAM 内容逐字一致；邻近编码的对象必须读出 0 |
| **T7** | **队列溢出**：强制 `q_full` 后 `STATUS[0]=1`，且 `marked=0`（不静默丢对象） |
| **T8** | **AXI 读错误**：注入 `RRESP=SLVERR` 后 `STATUS[1]=1`，且引擎不挂死 |
| **T-ABORT** | `CTRL[3]` 把挂死的引擎拉回 `S_IDLE` 并清 `DONE`；随后可再次完整运行 |
| **T-ABORT2** | **abort 后只写 `START`（不写 `CLEAR_Q`）**：队列/流水线里上一轮的残留必须已被 abort 丢弃，新图只标出它自己的活跃集、`STATUS=0x10`（idle、无错误）|
| **T-RACE** | **`run_start`/`abort` 同拍 R beat**：flush 当拍到达的旧响应必须被丢弃；未修复时数据 FIFO 留下上一轮的字，新 run 的第一笔 ref 被顶掉。每次必须命中 `RREADY=0` 窗口，未命中直接 FAIL（`sim/run_race_tb.bat` / `.sh`）|
| **T-CMDFIFO** | **`run_start`/`abort` 同拍命令 FIFO**：同拍不能再发下一条 AR；未修复时 `c0r=1→2` 且残留 `ARADDR=0x30000008`，修复后 `c0r=1→4`、无残留（`sim/run_cmdfifo_tb.bat` / `.sh`）|
| **T-MAXFAN** | 单个对象 **`ref_count=4095`**：引用 FIFO 顶到 80 深，对象头流仍必须排空（共享 R 通道不死锁），`marked` 精确、`STATUS=0x10` |
| **T-ROOTCLAMP** | **`root_count=0xFFFFFFFF`**：硬件必须钳到 256（`root_rd_addr` 只有 8 位），跑完且 `marked=256` |
| **T-STAR** | **4096 对象星形图**（root 0 → 1..4095）：`marked=4096`、`q_tail=0`（12 位指针回绕）、`STATUS=0x10` |
| **#6** | 未完成读事务数（outstanding AR）任何时刻 ≤ `MAXO`(8) |
| **AXI** | 协议检查器：`ARSIZE=3`/`ARLEN=0`/`ARBURST=INCR`/8 字节对齐/`ARID≤1`/`VALID` 在 `READY` 前不许撤销且载荷稳定 |

> 反向验证（全部实测过）：去掉对应修复后 —— T1 变 `marked=1`、T3 死锁超时、
> T4 超时、T5 变 `marked=0`、把 `ARSIZE` 改成 `2` 会报 1588 条 `[AXI][FAIL]`
> （而功能用例**照样通过**，因为存储模型不检查 ARSIZE）。
> T6/T7/T8 的反向验证：把 `0x28` 读回改成常量 → T6 报 2 处 FAIL；把 `err_ovf`
> 赋 0 → T7 `STATUS[0]=0`；把读主控的 `err` 去掉 → T8 `STATUS[1]=0`。
> 板级反向对照：新 `test_main` 跑在**旧比特流**上时，位图读回全部对不上
> （`bitmap readback=8 != MARKED=9`），换新比特流后 4/4 PASS。

## 5. 发布与上板

> 本仓库根目录即为完整工程；`artifacts/` + `tools/` 是上板验证所需的一站式内容。

### 下载启动镜像（Release）

`image.ub` 为 **43.2 MB**，不入仓库：二进制镜像随 Release 发布，
仓库只保留可复现的构建配置。
`BOOT.BIN` **不入库**（厂商 FSBL + U-Boot 无可 MIT 再分发，见 `NOTICE`），只在 GitHub Release 提供。

> ⚠️ 下表是 **GitHub Release 资产**的哈希。仓库与 tag **都不跟踪** `BOOT.BIN`（`artifacts/BOOT.BIN` 被 `.gitignore` 排除），
> 所以 tag 树里根本没有这个文件，不要试图用 tag 树核对哈希。
> v4.1 的变更与板级结果见「正确性、性能与测量」；P1 证据边界见本文顶部。

| 资产 | 烧录位置 | 大小 | SHA256 |
| --- | --- | --- | --- |
| `BOOT.BIN` | BOOT 分区根目录 | 18,582,724 B | `7487463acf9e34b6e2da8102229059ced67e505111fa81b21130f8aa14d1eb25` |
| `image.ub` | BOOT 分区根目录 | 43,295,771 B | `5b66851fdbfa44bca96f5ad7b7c881acbac2d993ca3e2211766a6cb05d887644` |
| `card-boot.zip` | 解压到 BOOT 分区根目录 | 5,952 B | `9e555af07027789080487247247bc55d942febd4e324ce5b6ba44340edbba642` |
| `card-userdata.zip` | 解压到 USERDATA 分区根目录 | 61,327 B | `0e372aff7b18fa291132d18e6f44efe878598812a691e225f73b72da82b123d2` |

> `card-userdata.zip` 里的 `cmark` 已重新编译：SHA256 `9ad738…`，23,256 B；卡包当前 61,327 B / `0e372a…`。

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
④ 数据分区 p2 由 /etc/fstab 开机自动挂在 /mnt/userdata，直接 cd 进去就能用
   （旧镜像若走 udev，则在 /run/media/USERDATA-mmcblk0p2；两条路径是同一个分区。临时手动挂载：sh /mnt/boot/mount_data.sh）
⑤ sh /mnt/userdata/run_gc.sh
```

测试输出同时打印到窗口并写入 `USERDATA` 分区上的 `gc_run_<时间戳>.log`。

### Windows 侧快捷指令

串口脚本自动识别 CH340；多根串口线时用 `-Port COMx` 指定。

| 做什么 | 命令 | 说明 |
| --- | --- | --- |
| 板子控制台 | 双击 `tools\fogccc.bat` | 开机日志 → 登录 shell，键盘直通板子；进入 shell 后自动用宿主时间发一次 `date -s` |
| 看串口日志 | `tools\log.bat` | 追加查看 `tools\logs\serial.log` |
| 运行 GC 基准 | `powershell -ExecutionPolicy Bypass -File tools\serial_run_gc.ps1` | 自动登录 root（先试空密码，不行再试 `root`）、挂载 `/mnt/userdata`、跑 `run_gc.sh`；必须同时看到 `PASSED (all invariants): n/n` 和 `RUN_GC_RC=0` 才算 PASS（最长约 7 分钟）|
| 大文件推送 | `... tools\serial_push_chunked.ps1 -Src <file> -Dest <path>` | 关回显 + 按提示符同步 + 分块 + 每块 md5；115200 下 18 MB 约 35 分钟 |
| 大文件续传 | `... tools\serial_push_resume.ps1 -Src <file> -Dest <path>` | 每块落到卡上 `parts/`，记录进度；掉线/断电后重跑同一条命令从断点继续（43 MB 的 `image.ub` 用这条，约 90 分钟）|
| 二进制清单 | `... tools\make_manifest.ps1` | 重新生成 `artifacts/SHA256SUMS`；CI 用 `-Check` 防止二进制改了清单没更新 |
| 刷新卡上副本 | `... tools\make_card.ps1` | 把 `tools/tests/`、`python/`、`csrc/` 里的脚本同步到 `artifacts/userdata/`（不动二进制）|
| C 基准参数扫描 | `powershell -ExecutionPolicy Bypass -File tools\tests\run_cmark_sweep.ps1` | 72 次参数扫描，性能表里 C 基线数据的来源 |
| 单条命令 | `powershell -ExecutionPolicy Bypass -File tools\serial_cmd.ps1 -Cmd "uname -a"` | 发一条命令并抓回显 |
| 指定串口 | 上面任意一条加 `-Port COM7` | 只在自动识别失败（多根串口线）时才需要 |

> 串口是**独占**的：同一时刻只能有一个窗口占用 COM 口。跑脚本前先关掉 `fogccc.bat`，
> 否则会报“拒绝访问/端口被占用”。

> 板上**没有 RTC、也没有网络**，所以每次上电时钟都退回 2018-03-09。`fogccc.bat` 和
> `serial_run_gc.ps1` 会用宿主时间自动发一次 `date -s`（只在 shell 提示符、控制台空闲时发），
> 卡上日志的时间戳因此是真实日期；不想被自动设置就加 `-NoTimeSync`。

### 板上测试命令速查

数据分区 p2 由 `/etc/fstab` 开机自动挂在 `/mnt/userdata`，登录后直接可用；
旧镜像若走 udev，路径是 `/run/media/USERDATA-mmcblk0p2`。两条路径是同一个分区，
写哪边都一样；临时手动挂载：`sh /mnt/boot/mount_data.sh`。以下命令均需 root。

#### 1. 中断通路验证

```sh
cd /mnt/userdata
D=/mnt/userdata sh tests/irq_drv_test.sh
```

插驱动 → arm → 跑一次 GC → 读计数 → 卸载。期望末行：

```
VERDICT: IRQ_DRIVEN_DONE_OK  (before='0 1' after='<N> 0')
```

#### 2. GC 主测试（FPGA vs Python 参照）

```sh
sh run_gc.sh                 # 默认 maxN=4096 trials=8 avg_refs=2
sh run_gc.sh 512 2 1         # 小规模快速验证
sh run_gc.sh 2048 5 3
```

| 参数 | 含义 | 默认 |
|---|---|---|
| `maxN` | 每轮对象数上限（硬件上限 4096）| 4096 |
| `trials` | 随机轮数 | 8 |
| `avg_refs` | 平均额外出度 | 2 |

期望：`PASSED (all invariants): trials/trials`，并打印相对同一进程内 Python BFS 参照的加速比（不是 CPython 的 `gc`）。

#### 3. 三方对比（FPGA / C / Python）

```sh
cd /mnt/userdata
./bin/test_main
```

`test_main` 默认就用 `/mnt/userdata/tests/gc_probe.py`（`/etc/fstab` 开机挂载）；
若分区在 `/run/media/USERDATA-mmcblk0p2`，程序会自动回退到那条路径，也支持显式传参。需要 root。

输出与判读见「三方对比（FPGA / C / CPython）」和「测量口径」。

与另外两条命令的分工：`test_main` 是**主对比**（FPGA / C / CPython）；`run_gc.sh` 跑可靠性 +
对照它自己的 Python BFS；`run_cmark.sh` 只比 FPGA vs C。`python3 python/benchmark.py` 是
同一 CPython 口径的批量版（10–4000 对象梯度）。

#### 4. C 基准（FPGA vs C）

```sh
sh run_cmark.sh              # 默认 4096 8 2
sh run_cmark.sh 2048 5 3
```

打印 `totals:` 与 `per object:` 两组时间；出现 `MISMATCH` 即失败。

#### 5. 重复性测试

```sh
sh run_repeat.sh 10          # 默认 10 次
```

三组：不同种子 vs Python 参照、不同图 vs C、同种子 5 次；末行 `REPEAT_DONE`。

#### 6. 单独调用

```sh
python3 gc_test.py 4096 8 2 --seed 12345   # 指定种子可复现
./bin/test_main                            # 4 项 C 测试（需 root）
insmod ko/fogccc-irq.ko                    # 仅插驱动
```

#### 7. 结果判读

| 关键行 | 含义 |
|---|---|
| `PASSED (all invariants)` | 功能正确 |
| `IRQ_DRIVEN_DONE_OK` | 中断通路正常 |
| `REPEAT_DONE` | 重复性测试完成 |
| `MISMATCH` / `FAIL` / `FAILED` | 失败 |

日志：`/mnt/userdata/logs/gc_run_<日期>_<时间>.log`。

#### 8. 常见问题

- `insmod: already loaded` → 先 `rmmod fogccc_irq`
- 打不开 `/dev/mem` → 必须是 root
- 没有 `IRQ_DRIVEN_DONE_OK` → 确认 PL 比特流已加载，且测试时 PL 处于 `done=0`（刚上电）
- `run_gc.sh` 找不到 `gc_test.py` → 脚本按自身目录找文件，整个目录要一起放在 `/mnt/userdata`
- `run_cmark.sh` 报找不到 `cmark` → 板上无 gcc，不能现场编译，直接用卡上的可执行文件

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
