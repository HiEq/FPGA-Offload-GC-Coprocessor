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
| 实测资源占用 | LUT 3,982 (1.44%) ／ FF 9,410 (1.70%) ／ BRAM 5.5 (0.73%) ／ DSP 0 |
| 时序         | WNS +3.217 ns ／ WHS +0.063 ns                                    |
| AXI HP 位宽  | 64-bit（每次读 1 拍 = 2 个 32-bit 字，8 字节对齐 + 半字选择）     |

## 目录结构

```
FOGCCC/
├── rtl/                    Verilog RTL 源码
│   ├── gc_top.v            顶层模块
│   ├── gc_regs.v           AXI-Lite 寄存器接口
│   ├── gc_mark_engine.v    BFS 标记状态机 (核心, 24 状态)
│   ├── gc_bitmap.v         标记位图 BRAM 4096×32
│   ├── gc_queue.v          BFS 队列 BRAM 4096×12
│   └── gc_axi_read.v       AXI HP 读主控
├── csrc/                   C 源码 (运行在 PS 端 Linux)
│   ├── fpga_gc.h           驱动头文件
│   ├── fpga_gc.c           驱动实现
│   └── test_main.c         测试主程序
├── python/                 Python 脚本
│   ├── fogccc.py           ctypes 绑定 + 多规模测试
│   └── benchmark.py        CPython 软件 GC 基准
├── vivado/
│   ├── build.tcl           Vivado 工程自动创建脚本
│   └── constraints.xdc     约束文件
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

### 3. 编译并运行测试 (板卡上)

```bash
# 传输 C 源码到板卡 (scp/U盘/串口)
cd <repo>/csrc

# 编译测试程序
gcc -O2 -o test_fpga fpga_gc.c test_main.c -lrt

# 运行 (需要 root)
sudo ./test_fpga
```

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
| 0x00 | CTRL | R/W | [0]=start [1]=clear_bm [2]=clear_q [31]=done |
| 0x04 | OBJ_BASE | R/W | 对象图 DDR 物理地址 |
| 0x08 | OBJ_COUNT | R/W | 对象总数 (最大 4096) |
| 0x0C | ROOT_COUNT | R/W | 根集数量 |
| 0x10 | MARKED | R | 标记对象数 |
| 0x14 | CYCLES | R | 硬件周期计数 |
| 0x18 | Q_HEAD | R | 队列头指针 |
| 0x1C | Q_TAIL | R | 队列尾指针 |
| 0x40+ | ROOT_LIST | W | 根集对象 ID 数组 |

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

三次上板实测，全部使用同一套严格判据（`gc_test.py`，`maxN=4096 trials=8 avg_refs=2`）。
"每对象周期" = HW cycles ÷ 活跃对象数（清位图是固定的 4096 拍，扣掉后更公平）。

|                | 原始设计 Ver1<br>(单笔未完成读) | Ver2<br>(多笔未完成读 + 快路径) | Ver3<br>(+ 对象头预取 + 竞态修复) |
| -------------- | ------------------------------- | ------------------------------- | --------------------------------- |
| 判定           | 8/8                             | 8/8                             | **8/8**                           |
| 总 HW cycles   | 1,804,791                       | 557,091                         | **484,034**                       |
| 活跃对象合计   | ~20,010                         | 14,441                          | 12,449                            |
| 每对象周期     | **90.2**                        | 38.6                            | **38.9**（扣清位图 36.3）         |
| vs CPython     | 37.5~39.5x                      | 100~126x                        | **104~123x**                      |
| N 范围         | 541~3895                        | 529~4048                        | 639~3872                          |

### 提升幅度

```
每对象周期    90.2 → 38.9         = 2.32x
总 HW cycles  1,804,791 → 484,034 = −73%
```


### 优化手段（三步）

| # | 手段 | 效果 |
|---|---|---|
| 1 | **多笔未完成读**：`gc_axi_read` 改成"命令 FIFO + 数据 FIFO"的读命令队列，引擎可连续压入地址互不依赖的读 | 每个对象从 `2 + ref_count` 次**串行**往返 → 2 次**并发**往返 |
| 2 | **引用阶段压入/取回交错** + **对象头投机预取**：引用命令边压边收；当前对象引用命令压完后立刻从队列弹下一个对象、把它的两笔头读也压进去 | 下一个对象的头延迟被完全掩盖 → 每个对象只暴露 **1 次往返**；同时**去掉了 `REF_MAX=64` 静默截断**的隐患 |
| 3 | **逐引用快路径**：位图改成读写地址独立的简单双口 BRAM；取到引用值那一拍就发读地址，下一拍"判定+置位+入队"一拍完成 | 每次引用 6 拍 → **2 拍** |

配套：为统一时钟域把 AXI HP 从 FCLK1 (200MHz) 挪到 FCLK0 (100MHz)，
省掉整套 2FF CDC 同步器（本设计是**延迟受限**而非带宽受限，100MHz 足够）。

### 对优化 C 的参考对比

板上带一个独立的 C 基准 `cmark`（静态 ARM 二进制，`run_cmark.sh` 一键跑）：
在**同一张图**上同时跑硬件和 C 两遍，三个实现的标记数必须都等于已知真值 L。

**实测（72 次；4 组参数）**：每对象 HW 38.3~41.2 拍，各组结果高度一致。

| 组 | maxN / trials / avg_refs | HW 拍/对象 | C-uncached | C-cached | **HW / C-unc** | **HW / C-cac** |
| -- | ------------------------ | ---------- | ---------- | -------- | -------------- | -------------- |
| 1  | 4096 / 24 / 2            | 38.3       | 542 ns     | 158 ns   | **1.4x**       | **0.4x**       |
| 2  | 4096 / 16 / 4            | 40.8       | 664 ns     | 175 ns   | **1.6x**       | **0.4x**       |
| 3  | 4096 / 16 / 1            | 38.3       | 475 ns     | 126 ns   | **1.2x**       | **0.3x**       |
| 4  | 2048 / 16 / 2            | 41.2       | 531 ns     | 116 ns   | **1.3x**       | **0.3x**       |

72 次全部 OK —— 三个实现（HW / C 非缓存 / C 缓存）的标记数都等于已知真值 L。

**结论**：

- 对同样走非缓存 DDR的 C 标记，硬件快 1.2~1.6x
- 对数据已驻留 CPU cache的进程内 C 标记，硬件反而慢 2.5~3.3x
  （HW 382 ns vs C-cached 116~175 ns）。
- avg_refs，越大硬件越占优（1.6x）

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
│                     fogccc_proj/ 由 build.tcl 生成, 已 .gitignore
├─ csrc/              PS 端 C 驱动 (fpga_gc.h/.c, test_main.c)
├─ python/            CPython 侧 ctypes 绑定 + 软件基准
├─ petalinux/         PetaLinux 必须改的配置项
├─ tools/             PC 端串口控制台 + 板级测试脚本
│    fogccc.bat         统一控制台
│    monitor_com5.ps1   后端
│    gc_test.py         板级 FPGA mark 测试
│    log.bat            查看 com5.log
│    fallback/          备用: 串口推送 / 纯裸控制台
├─ artifacts/         要拷到 TF 卡的构建产物
│    BOOT.BIN  image.ub  boot.scr        -> BOOT 分区
│    gc_test.py  run_gc.sh               -> USERDATA 分区
│    mount_data.sh  test_fpga  system.dtb  zynq_fsbl.elf
└─ BUILD_GUIDE.md     构建步骤
```

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
