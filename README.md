# FOGCCC — FPGA Offload GC Coprocessor for CPython

[![Platform](https://img.shields.io/badge/Platform-Xilinx%20Zynq--7000%20XC7Z100-blue)](#platform)
[![RTL](https://img.shields.io/badge/RTL-Verilog%202001-green)](#rtl)
[![Vivado](https://img.shields.io/badge/Vivado-2026.1-orange)](#quick-start)
[![License](https://img.shields.io/badge/License-MIT-yellow)](#license)

FPGA 异步垃圾回收协处理器原型 — 将 CPython 的 GC **标记阶段（Mark Phase）** 卸载到 FPGA 硬件，把标记阶段的指针追逐交给硬件，减轻 CPU 负担。

## 架构概览

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

### 工作流程

1. ARM PS 上的 CPython 运行程序，触发 GC
2. C 驱动通过 `/dev/mem` 将对象图写入 DDR (`0x1E000000`)
3. C 驱动写 AXI-Lite 寄存器启动 FPGA 标记引擎
4. FPGA 引擎执行 BFS 标记
5. ARM PS 轮询完成标志，读取标记结果和周期计数
6. CPython 据此跳过/回收未标记对象

## Platform

| 项目         | 规格                                                              |
| ------------ | ----------------------------------------------------------------- |
| FPGA         | Xilinx Zynq-7000 XC7Z100FFG900-**2**                              |
| 逻辑资源     | 277,400 LUT / 554,800 FF                                          |
| BRAM         | 19.2Mb (545块 36Kb)                                               |
| DSP          | 2,020                                                             |
| PS CPU       | 2× ARM Cortex-A9 @ 666.67MHz                                      |
| PS 内存      | DDR3 @ 533MHz                                                     |
| 工具链       | Vivado 2026.1 / PetaLinux 2026.1                                  |
| 时钟域       | 单一时钟域 FCLK0 = 100MHz —— 引擎 / AXI-Lite / AXI HP 同一域，无 CDC |
| 实测资源占用 | LUT 7,481 (2.70%) ／ FF 18,298 (3.30%) ／ BRAM 5.5 (0.73%) ／ DSP 0 |
| 时序         | WNS +2.016 ns ／ WHS +0.042 ns                                    |
| AXI HP 位宽  | 64-bit（每次读 1 拍 = 2 个 32-bit 字，8 字节对齐 + 半字选择）     |

## 目录结构

```
FOGCCC/
├── rtl/                    Verilog RTL 源码
│   ├── gc_top.v            顶层 (AXI-Lite + AXI3 HP, 单时钟域无 CDC)
│   ├── gc_regs.v           AXI-Lite 寄存器接口 (12 位地址 / 含 STATUS)
│   ├── gc_mark_engine.v    BFS 状态机 + 对象头预取"侦察兵" + 引用发射器
│   ├── gc_bitmap.v         标记位图 BRAM 4096×32 (读/写地址独立)
│   ├── gc_queue.v          BFS 队列 BRAM 4096×12 (带 count, 可安全用满)
│   └── gc_axi_read.v       AXI3 读主控: 双流 (ID=0 引用 / ID=1 对象头)
├── sim/                    xsim 自检仿真
│   ├── tb_gc_top.v         自检 testbench (主用例 + T1..T8 + STATUS)
│   ├── axi_proto_check.v   AXI3 读通道协议检查器 (ARSIZE/ARLEN/ARBURST/对齐/VALID 稳定)
│   ├── run_sim.bat         一键仿真 (PASS = 250/250、孤岛 0)
│   └── lat_sweep.bat       延迟扫描 LAT=1..32 (量"延迟敏感度"/斜率)
├── csrc/                   C 源码 (PS 端 Linux)
│   ├── fpga_gc.h / .c      驱动
│   ├── test_main.c         测试主程序
│   └── build_cmark.sh      cmark 交叉编译 (工具链从脚本位置推导)
├── python/                 ctypes 绑定 + 基准
├── vivado/
│   ├── build.tcl           首次建工程 (BD + 综合 + 实现 + XSA)
│   ├── build_rtl_only.tcl  只改 RTL 的快速重编 (复用 BD)
│   └── constraints.xdc
├── tools/                  串口控制台 / 板上自动化 / JTAG 烧写
├── driver/                 内核中断驱动 + PetaLinux 模块 recipe
├── petalinux/              工程骨架 (config/rootfs_config/meta-user) + 一条命令构建
├── artifacts/              要拷到 TF 卡的构建产物
├── legacy/original-v1/     优化前 RTL 存档 (tag v1-original)
├── AGENTS.md               本项目对 AI 参与者的工程约束
├── petalinux/BUILD_GUIDE.md 构建步骤
└── README.md               本文件
```

## Quick Start

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

**方式 B: Linux 动态加载 (板卡上)**
```bash
sudo cp system_wrapper.bit /lib/firmware/fogccc.bit
echo fogccc.bit > /sys/class/fpga_manager/fpga0/firmware
cat /sys/class/fpga_manager/fpga0/state
```

### 3. 编译并运行测试 (板上没有 gcc，在 PC 上交叉编译)

```bash
# PC: 用 PetaLinux SDK 交叉编译（SDK 只需装一次，之后 source 环境脚本）
source ~/petalinux_sdk/environment-setup-cortexa9t2hf-neon-amd-linux-gnueabi
$CC -O2 -o test_main csrc/fpga_gc.c csrc/test_main.c

# 拷到 USERDATA 分区后，在板上运行（需要 root）
cd /run/media/USERDATA-mmcblk0p2
sudo ./bin/test_main
```

`test_main` 会用 `popen` 调用 `tests/py_mark.py` 测 CPython 基准；默认路径就是上面卡上的位置，
也可以 `./test_main /path/to/py_mark.py` 显式指定。表里三个时间都是实测：

| 列 | 来源 |
| --- | --- |
| `FPGA us` | `CYCLES` 寄存器 / 100 MHz（引擎耗时，不含驱动里的 `usleep`） |
| `C us` | `fpga_gc_sw_mark()`，同一张图、同一套 BFS 的 C 实现 |
| `CPython ms` | `py_mark.py` 独立进程、独立实现的 Python BFS |

2026-10-17 实测（XC7Z100，PL 100 MHz）：

```
Objects  marked   FPGA us   C us      CPython ms   vs C    vs CPython
10       9        44.2      13.7      0.464         0.3x    11x
100      96       57.1      60.1      4.205         1.1x    74x
1000     945      184.7     517.1     43.033        2.8x    233x
4000     3766     646.1     2148.3    169.802       3.3x    263x
```

小图（<100 对象）FPGA 反而慢，因为固定启动开销约 4400 拍；`marked < Objects` 是随机图里
从根 0 不可达的对象，三个实现标记的是同一张图，所以比较是公平的。

### 4. Python 测试 (板卡上)

```bash
# 编译共享库
cd <repo>/csrc
gcc -O2 -shared -fPIC -o libfogccc.so fpga_gc.c
cp libfogccc.so ../python/

# 运行多规模测试
cd ../python
sudo python3 fogccc.py
```

### 5. 软件基准 (任意 Linux)

```bash
python3 python/benchmark.py
```

## Register Map

| 偏移 | 名称 | R/W | 说明 |
|------|------|-----|------|
| 0x00 | CTRL | R/W | [0]=start [1]=**保留**（旧 clear_bm，位图由引擎每轮自动清） [2]=clear_q [31]=done |
| 0x04 | OBJ_BASE | R/W | 对象图 DDR 物理地址 |
| 0x08 | OBJ_COUNT | R/W | 对象总数 (最大 4096) |
| 0x0C | ROOT_COUNT | R/W | 根集数量 |
| 0x10 | MARKED | R | 标记对象数 |
| 0x14 | CYCLES | R | 硬件周期计数 |
| 0x18 | Q_HEAD | R | 队列头指针 |
| 0x1C | Q_TAIL | R | 队列尾指针 |
| 0x20 | STATUS | R | [0]=队列溢出 [1]=AXI 读错误 [2]=引用流失步 [3]=对象头非法（`ref_count>4096`）（每次 start 清零） |
| 0x24 | BM_ADDR | R/W | 位图探针地址（0~4095，只在引擎空闲时有效） |
| 0x28 | BM_DATA | R | 位图探针数据 = `mem[BM_ADDR]`，1 拍后更新；软件用它逐对象读回标记 |
| 0x40+ | ROOT_LIST | W | 根集对象 ID 数组（0x40~0x43F，最多 256 个） |

## 关键设计参数

| 参数 | 值 | 为什么是这个值 |
| --- | --- | --- |
| `MAXO` | **8** | 未完成读上限，与 PS7 `S_AXI_HP0` 自己声明的 `NUM_READ_OUTSTANDING=8` 一致；再大只会被 `ARREADY` 反压 |
| `QD` | **80** | 每条流的命令/数据 FIFO 容量（存储体 128 深、指针 7 位） |
| `PD` | **4** | 对象头暂存环深度 = **预取深度**（领先最多 4 个对象） |
| `DQD` | **8** | 引用描述符队列深度（对象头填好即入队，由 issuer 独立发命令） |
| 对象上限 | **4096** | 12 位对象 ID / 位图 4096×32 / 队列 4096 深 |
| AXI 协议 | **AXI3** | Zynq-7000 HP 口原生协议：`ID_WIDTH=6`、单拍、`ARSIZE=3`(8 字节) |
| 流 ID | **0 = 引用, 1 = 对象头** | 两流各有独立数据 FIFO；同 ID 保序、异 ID 互不阻塞 |
| 时钟 | **FCLK0 = 100MHz** | 引擎 / AXI-Lite / AXI HP 同一域，**无 CDC** |
| 位图 | 4096×32 = 128 Kb | 对象 x 的状态 = `mem[x]` 的第 `x%32` 位 |
| 队列 | 4096×12 = 48 Kb | 带 `count` 判空/满；旧版卡在 4000 且**静默丢弃**，现已改成报告 `err_ovf` |

## Object Graph DDR Format

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

## 性能实测

四次上板实测，全部使用同一套严格判据（`gc_test.py`，`maxN=4096 trials=8 avg_refs=2`）。
"每对象周期" = HW cycles ÷ 活跃对象数（清位图是固定的 4096 拍，扣掉后更公平）。

> **可复现**：`gc_test.py` 现在支持 `--seed N` 并会把种子打印在日志里
> （不传则从时钟取一个并打印），同一种子的两次运行图**完全一致**
> （N/exp 相同）。HW cycles 仍有 DDR 响应带来的抖动，实测同一张图
> （seed 424242，N=2578）跑 5 次为 33673 / 33679 / 33698 / 33808 / 33828 拍，
> 极差 **155 拍 = 0.46%** —— 引用性能时请带上这个误差。
> 例：`python3 gc_test.py 4096 8 2 --seed 424242`

|                | 原始设计 Ver1<br>(单笔未完成读) | Ver2<br>(多笔未完成读 + 快路径) | Ver3<br>(+ 对象头预取 + 竞态修复) | Ver4<br>(+ 引用流水 + 6 项修复) |
| -------------- | ------------------------------- | ------------------------------- | --------------------------------- | ------------------------------- |
| 判定           | 8/8                             | 8/8                             | **8/8**                           | **8/8**                         |
| 总 HW cycles   | 1,804,791                       | 557,091                         | **484,034**                       | 188,850                         |
| 活跃对象合计   | ~20,010                         | 14,441                          | 12,449                            | 10,191                          |
| 每对象周期     | **90.2**                        | 38.6                            | **38.9**（扣清位图 36.3）         | **15.3**（扣清位图）            |
| vs CPython     | 37.5~39.5x                      | 100~126x                        | **104~123x**                      | **223~275x**                    |
| N 范围         | 541~3895                        | 529~4048                        | 639~3872                          | 856~3222                        |

> ⚠️ 各列的总 HW cycles 来自**不同的随机图**（活跃对象数见"活跃对象合计"行），
> 只有 **每对象周期** 是可比的。

### 仿真回归

`sim\run_sim.bat` 一次跑完下面全部检查（**全过才算 PASS**）：

| 检查 | 内容 |
| --- | --- |
| 主用例 | N=300 / 活跃 250 / 孤岛 50；标记数、队列尾、位图逐位比对 |
| STATUS | `0x20` 必须为 0（无队列溢出 / 无 AXI 读错误 / 无引用流失步 / 无非法对象头） |
| **T1** | **连续两次运行**：`marked` 两次都必须是 2（回归 `prev_ref` 跨运行残留） |
| **T2** | **重复根**（同一 root 写两次）：只算一次 |
| **T3** | **流水 AW**（AW/W 双线程背靠背两笔写）：两笔都必须落到正确寄存器 |
| **T4** | **非法对象头**（`ref_count=0xFFFFFFFF`）：必须被拒、`STATUS[3]=1`、`marked` 仍是活跃区 |
| **T5** | **12 位寄存器地址**：`root[60]` 在 `0x130`，写地址截断到 8 位会标记 0 个对象 |
| **T6** | **位图探针**：`0x24/0x28` 读回必须与 BRAM 内容逐字一致；邻近编码的对象必须读出 0 |
| **T7** | **队列溢出**：强制 `q_full` 后 `STATUS[0]=1`，且 `marked=0`（不静默丢对象） |
| **T8** | **AXI 读错误**：注入 `RRESP=SLVERR` 后 `STATUS[1]=1`，且引擎不挂死 |
| **#6** | 在飞 AR 数任何时刻 ≤ `MAXO`(8) |
| **AXI** | 协议检查器：`ARSIZE=3`/`ARLEN=0`/`ARBURST=INCR`/8 字节对齐/`ARID≤1`/`VALID` 在 `READY` 前不许撤销且载荷稳定 |

> 反向验证（全部实测过）：去掉对应修复后 —— T1 变 `marked=1`、T3 死锁超时、
> T4 超时、T5 变 `marked=0`、把 `ARSIZE` 改成 `2` 会报 1588 条 `[AXI][FAIL]`
> （而功能用例**照样通过**，因为存储模型不检查 ARSIZE）。
> T6/T7/T8 的反向验证：把 `0x28` 读回改成常量 → T6 报 2 处 FAIL；把 `err_ovf`
> 赋 0 → T7 `STATUS[0]=0`；把读主控的 `err` 去掉 → T8 `STATUS[1]=0`。
> 板级反向对照：新 `test_main` 跑在**旧比特流**上时，位图读回全部对不上
> （`bitmap readback=8 != MARKED=9`），换新比特流后 4/4 PASS。

### 中断链路

`gc_top.irq_o = done` 接到 `ps7_0/IRQ_F2P[0]`，即 **GIC 中断 ID 61**
（`ISPENDR1` bit 29）。`driver/` 里有一个最小模块验证整条链路：

```
insmod fogccc-irq.ko          # 映射 SPI 61 + request_irq，生成 /dev/fogccc_irq
echo arm > /dev/fogccc_irq    # 使能（done=0 时不会触发）
python3 gc_test.py 1024 1 2 --seed 11   # done 0 -> 1
cat /dev/fogccc_irq           # "1 0 <virq>"  ← 中断已触发，处理函数自动关线
```

实测：`before arm 0 0 / after arm 0 1 / after run 1 0`，`VERDICT: IRQ_DRIVEN_DONE_OK`。
两个坑见 `driver/README.md`（hierarchy 域没有 `.map`；`fwspec.param[1]` 是
SPI 编号 = ID − 32）。

### 提升幅度

```
每对象周期    90.2 → 15.3          = 5.9x     (Ver1 → Ver4, run_gc)
             38.3 → 17.5          = 2.19x    (Ver3 → Ver4, cmark 同一张图, 最严格)
总 HW cycles  1,804,791 → 484,034  = −73%     (Ver1 → Ver3)
```

**数据出处**（2026-10-17 实测）：
- 命令：`run_gc.sh`（maxN=4096 trials=8 avg_refs=2）、`run_cmark.sh` 4 组共 72 次
- 比特流：`632ECC915C81C7C29AA8F22D60460973`
- BOOT.BIN：`B9E5DC1DA5D7430334387E889CA2D45C`
- 板卡：XC7Z100-FFG900-2，AXI HP 与引擎同在 FCLK0 = 100MHz，DDR3 @ 533MHz


### 优化手段（四步）

| # | 手段 | 效果 |
|---|---|---|
| 1 | **多笔未完成读**：`gc_axi_read` 改成"命令 FIFO + 数据 FIFO"的读命令队列，引擎可连续压入地址互不依赖的读 | 每个对象从 `2 + ref_count` 次**串行**往返 → 2 次**并发**往返 |
| 2 | **引用阶段压入/取回交错** + **对象头投机预取**：引用命令边压边收；当前对象引用命令压完后立刻从队列弹下一个对象、把它的两笔头读也压进去 | 下一个对象的头延迟被完全掩盖 → 每个对象只暴露 **1 次往返**；同时**去掉了 `REF_MAX=64` 静默截断**的隐患 |
| 3 | **逐引用快路径**：位图改成读写地址独立的简单双口 BRAM；取到引用值那一拍就发读地址，下一拍"判定+置位+入队"一拍完成 | 每次引用 6 拍 → **2 拍** |
| 4 | **引用流水**：把"发引用读命令"从主状态机剥离成独立 issuer，描述符在**对象头填好的那一刻**就入队，最多领先 4 个对象；对象头改走**独立的 AXI 流**（`ID=1`），与引用流（`ID=0`）互不阻塞 | 引用读延迟被后续对象的处理盖住：LAT 扫描斜率 **1.00 → 0.71**；每对象 **38.3 → 17.5 拍** |

配套：为统一时钟域把 AXI HP 从 FCLK1 (200MHz) 挪到 FCLK0 (100MHz)，
省掉整套 2FF CDC 同步器（本设计是**延迟受限**而非带宽受限，100MHz 足够）。

### 对优化 C 的参考对比

板上带一个独立的 C 基准 `cmark`（静态 ARM 二进制，`run_cmark.sh` 一键跑）：
在**同一张图**上同时跑硬件和 C 两遍，三个实现的标记数必须都等于已知真值 L。

**实测（72 次；4 组参数）**：每对象 HW 17.5~20.6 拍，72 次全部 OK。

| 组 | maxN / trials / avg_refs | HW 拍/对象 | C-uncached | C-cached | **HW / C-unc** | **HW / C-cac** |
| -- | ------------------------ | ---------- | ---------- | -------- | -------------- | -------------- |
| 1  | 4096 / 24 / 2            | 17.5       | 540 ns     | 160 ns   | **3.1x**       | **0.9x**       |
| 2  | 4096 / 16 / 4            | 20.2       | 660 ns     | 175 ns   | **3.3x**       | **0.9x**       |
| 3  | 4096 / 16 / 1            | 17.7       | 472 ns     | 130 ns   | **2.7x**       | **0.7x**       |
| 4  | 2048 / 16 / 2            | 20.6       | 533 ns     | 122 ns   | **2.6x**       | **0.6x**       |

72 次全部 OK —— 三个实现（HW / C 非缓存 / C 缓存）的标记数都等于已知真值 L。

**结论**：

- 对同样走非缓存 DDR 的 C 标记，硬件快 **2.6~3.3x**
- 对数据已驻留 CPU cache 的进程内 C 标记，硬件 **0.6~0.9x**
  （即还慢 1.1~1.7x，但比优化前的 2.5~3.3x 已大幅接近打平）
- avg_refs 越大硬件越占优（**3.3x**）

> README 的主对比仍用 CPython，那是本项目最初的对照基线；
> `cmark` 只用来量一下相对优化 C的位置。

## Debug & Monitoring

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

## License

MIT License

---

# 交付包 / 上板验证包

本仓库根目录即为**完整工程**；`artifacts/` + `tools/` 是上板验证所需的一站式内容。

## 目录

```
FPGA Offload GC Coprocessor for CPython/
├─ rtl/               Verilog RTL 源码
│    gc_top.v          顶层 (AXI-Lite + AXI HP, 单一时钟域无 CDC)
│    gc_regs.v         AXI-Lite 寄存器文件
│    gc_mark_engine.v  BFS 标记状态机 (核心)
│    gc_bitmap.v       标记位图 4096x32 BRAM (读/写地址独立, 简单双口)
│    gc_queue.v        BFS 队列 4096x12 BRAM
│    gc_axi_read.v     AXI HP 读命令队列 (多笔未完成读, 64 位对齐 + 半字选择)
├─ vivado/            build.tcl 首次建工程+综合+实现+导出 XSA ; build_rtl_only.tcl 只改 RTL 时快速重编
│                     bd_if_dump.txt  BD 里 gc_top 的连线记录 ; constraints.xdc 时序约束
│                     fogccc_proj/ 由 build.tcl 生成, 已 .gitignore
├─ csrc/              PS 端 C 驱动 (fpga_gc.h/.c, test_main.c)
├─ python/            CPython 侧 ctypes 绑定 + 软件基准
├─ petalinux/         PetaLinux 必须改的配置项
├─ tools/             PC 端串口控制台 + 板级测试脚本
│    fogccc.bat         统一控制台
│    monitor_com5.ps1   后端
│    gc_test.py         板级 FPGA mark 测试 (--seed 可复现)
│    log.bat            查看 com5.log
├─ artifacts/         要拷到 TF 卡的构建产物 (按分区摆放, 详见 artifacts/README.md)
│    BOOT.BIN  image.ub  boot.scr  system.dtb
│    zynq_fsbl.elf  mount_data.sh          -> BOOT 分区
│    userdata/                             -> USERDATA 分区
│        run_gc.sh  run_cmark.sh  run_repeat.sh  gc_test.py  cmark
│        bin/test_main   tests/(irq_drv_test.sh, py_mark.py)
│        ko/(板上构建产出, 不入库)   logs/(板上运行时生成)
└─ petalinux/BUILD_GUIDE.md     构建步骤
```

## 下载启动镜像（Release）

`image.ub` 约 106MB，超过 GitHub 单文件 100MB 限制，因此**不入仓库**，只放在 Release 附件里。
`BOOT.BIN` 虽然仓库里有，Release 里也一并提供，做到**开箱即用**。

| Release | 对应版本 | `BOOT.BIN` md5 | `image.ub` md5 |
| --- | --- | --- | --- |
| [`v4-optimized`](../../releases/tag/v4-optimized) | 当前优化版（`dev-hieq`）：双流流水 + 对象头预取 + 位图读回探针 + rootfs 精简 | `04CFEC20A279CFA2F03225481D42D0EF` | `2B446CFB755CB4FC9CB9A15A159BE6E7` |
| `v3-optimized`（资产 `BOOT.BIN-v3-optimized`） | 优化版（`main`：多笔未完成读 + 预取 + 竞态修复，AXI HP 100MHz 单时钟域） | `D62AC4EBACEF8F4C8B6C208E5088A563` | `1CEDF5898D3429AFCD390CEBD75192F5` |
| `v1-original`（资产 `BOOT.BIN-v1-original`） | 原始未优化版（标签 `v1-original`：单笔未完成读，AXI HP 200MHz + CDC） | `A33C0591E8455C798955DEB18493B0E6` | `1CEDF5898D3429AFCD390CEBD75192F5` |

> 三个版本的镜像都挂在同一个 release [`v4-optimized`](../../releases/tag/v4-optimized) 下，按资产名区分。

> **两个版本的 `image.ub` 完全相同** —— 优化只动了 PL 侧（RTL + 比特流），
> PS7 的 20 条 `CONFIG.PCW_*` 参数（`FCLK0=100MHz` / `FCLK1=200MHz` / `DDR 533.33MHz` …）
> 一个字都没改，所以设备树和内核是同一份。
>
> 但 **`BOOT.BIN` 必须配对**：跑 Ver1 就用 Ver1 的那块，别拿 Ver3 的（那是新设计的比特流）。
> 两块文件大小相同（18,582,708 B）但内容不同，用 md5 区分。

## TF 卡布局

| 分区 | 类型 | 卷标 | 内容 |
|---|---|---|---|
| p1 | FAT32 | (BOOT) | `BOOT.BIN` / `image.ub` / `boot.scr` / **`uEnv.txt`** / `mount_data.sh` |
| p2 | FAT32 | **USERDATA** | `gc_test.py` / `run_gc.sh` / 工程文件 / 日志 `gc_run_*.log` |

> ⚠️ `USERDATA` 必须是 **FAT32**：板子内核没有编 exFAT (`# CONFIG_EXFAT_FS is not set`)。
> Windows 图形界面无法创建 >32GB 的 FAT32，用板子自己格式化：
> `mkfs.vfat -F 32 -n USERDATA /dev/mmcblk0p2`

## 上板流程

```
① 双击 tools/fogccc.bat
② 板子上电
   出现 linux login:
③ root  + 回车                    (空密码)
④ mkdir -p /mnt/userdata && mount /dev/mmcblk0p2 /mnt/userdata
⑤ sh /mnt/userdata/run_gc.sh
```

测试输出同时打印到窗口并写入 `USERDATA` 分区上的 `gc_run_<时间戳>.log`。
