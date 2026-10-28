# 面向托管堆的 FPGA GC 协处理器（FOGCCC）设计报告

| 项目 | 内容 |
|---|---|
| 赛道与组别 | 2026 FPGA 赛道 · 自主选题（初级组）【待补：以报名信息为准】 |
| 参赛队 | 【待补：队名】 |
| 队员 | 【待补：姓名、学校、年级】 |
| 指导教师 | 【待补】 |
| 目标平台 | OpenSoc OS-ZYNQ7100 Lite（Zynq-7000 XC7Z100FFG900-2，1 GB DDR3） |
| 完成日期 | 2026-10-28 |

## 摘要

本作品在 Zynq-7000 XC7Z100 上实现托管堆垃圾回收的标记与空闲扫描协处理器。对象图驻留
DDR，PL 通过 AXI HP 以单拍读遍历引用关系，PS 只负责构图、启动与回收决策。

两组数据分开表述：8 轮 4096 对象扫描（9,103 个活跃对象）为 15.2 拍/对象；单张 4000
对象图的时间对比为 FPGA 645.4 µs、未缓存 C 2038.3 µs、Python 脚本 142.787 ms，对应
3.2 倍与 221 倍。两者数据集不同，不互为换算。作品不接入具体语言运行时，测量范围限定为
标记与空闲扫描两个阶段。

## 1. 选题背景与创新点

### 1.1 背景

托管语言（Java、Go、JavaScript 等）的垃圾回收以标记为主：从根集出发逐对象读取引用数组，
再按对象头中的引用数继续遍历。负载特征是对象体大、引用关系稀疏、访存随机，CPU 侧受
DDR 往返延迟约束明显。标记只做位图置位与队列管理，指令少、访存多，适合下沉到可编程逻辑。

### 1.2 前人工作

| 工作 | 平台与方法 | 主要结论 | 与本作品的关系 |
|---|---|---|---|
| Maas 等，ISCA 2018 [1] | RISC-V SoC 内的近内存 GC 加速器 | 标记阶段为顺序 CPU 的 4.2 倍，面积约为 64 KB SRAM（18.5%） | 证明标记可硬件化；本作品改用现成 Zynq 板卡与 AXI HP，不修改 SoC |
| Faes 等，FPL 2005 [2] | FPGA 辅助 Java GC，硬件实例保存引用 | 量化硬件保存引用对 GC 成本的影响 | 早期 FPGA GC 探索；依赖语言运行时，本作品与语言解耦 |
| Ramsay 与 Stewart，Haskell 2024 [3] | FPGA 并发混合 GC（标记清扫 + 引用计数） | 15 个基准中 14 个的 GC 时间为 GHC 的 4.1% | 面向非严格函数语言与并发回收；本作品先做 stop-the-world 与增量屏障 |
| Detlefs 等，ISMM 2004 [4] | G1：分区域并发收集器 | 以区域为单位控制停顿 | 软件侧停顿与吞吐的基线；本作品不替代运行时 |
| Bacon 等，2003 [5] | Metronome：实时软件收集器 | 以时间片控制停顿 | 说明软件路径的上限；硬件路径的对照对象 |

上表的数字来自各自平台与负载，不能直接横向比较；本报告只在同一块板、同一张图上比较
FPGA、C 与 Python 三种实现。相关工作的共同点是“标记是访存受限的规则循环”，差别在于
加速位置（近内存、SoC 内、FPGA 逻辑）、语言耦合程度与是否并发。

### 1.3 作品范围

- 回收策略：stop-the-world。软件写 START，轮询 DONE，再读标记结果。
- 规模：对象上限 4096，图区上限 1 MiB，根集上限 256。
- 不接入任何语言运行时的 GC 模块；对象图由调用者按约定布局写入。

### 1.4 创新点

1. 对象图驻留 DDR 的 side table 布局：每个对象 16 字节头（ID、引用数、引用数组地址、
   保留）加一段连续引用数组，结尾用 0xFFFFFFFF 标记。布局与宿主语言无关，C 与 Python
   共用同一份契约。
2. 双流单拍 AXI HP 读引擎：引用走 ID=0、对象头走 ID=1，命令与数据各用一组 FIFO，
   支持 8 笔未完成读、对象头投机预取与引用流水，使多数对象只暴露两次往返，其中一次
   被预取覆盖。
3. 增量屏障协议：脏边以 (tag, id) 形式推送，硬件按 id 回执，软件可做逐条确认与效果验收；
   flush 为预置式，迟到的写副本不会清除当前 epoch。
4. 命令写标记：CTRL 与 DIRTY_PUSH 的写数据高 12 位必须匹配固定值，错配的写被应答后丢弃，
   用于抵抗本平台非相邻重投递造成的地址与数据错配。
5. 数据寄存器写后校验：配置类寄存器写入后回读并重试，读不回来时向上报错，避免静默改变
   图参数。

## 2. 设计原理与功能框图

### 2.1 总体结构

```
+---------------------------------------------------------------------------------+
| Zynq-7000 XC7Z100                                                               |
| PS (ARM Cortex-A9 x2 @ 800 MHz)        PL (FCLK0 = 100 MHz)                     |
|   host app / SW GC                       gc_top                                 |
|   fpga_gc.c    -- AXI-Lite -------->     |- gc_regs          registers          |
|   fogccc.py                              |- gc_mark_engine   BFS FSM            |
|   /dev/mem mmap -- AXI HP (64-bit) ->    |- gc_bitmap        4096x32            |
|                                          |- gc_queue         4096x12            |
|                                          |- gc_freelist      free scan          |
|                                          |- gc_dirty_fifo    dirty-edge source  |
|                                          `- gc_axi_read      dual-stream reader |
|                                                                                 |
| DDR3 0x1E000000: object graph (written by the host)                             |
+---------------------------------------------------------------------------------+
```

【图 2-1 待补：按上图重绘为矢量图；本地已生成 SVG/PNG，见附录 A。】

### 2.2 模块职责

| 模块 | 职责 |
|---|---|
| gc_top | 顶层连线、地址译码、启动/中止门控、状态汇总 |
| gc_regs | AXI-Lite 寄存器、命令写标记校验、写后回读支持 |
| gc_mark_engine | 标记状态机：取对象头、遍历引用、入队、消费脏边、完成判定 |
| gc_bitmap | 4096 个 32 位字，每位对应一个对象；双口 BRAM，读地址与写地址独立 |
| gc_queue | 4096×12 对象队列，记录已标记待展开的 ID |
| gc_freelist | 标记完成后扫描未标记对象，输出空闲计数与 ID |
| gc_dirty_fifo | 脏边第二工作源，256 深，满时置粘滞溢出位 |
| gc_axi_read | 双流单拍读：命令 FIFO、数据 FIFO、在途计数、启动/中止清理 |

位图按“每对象一位、按 32 位字对齐”实现：对象 x 使用第 x 个字的第 x%32 位。这样每次
置位只写一个固定的字地址，避免读改写；代价是 4096×32 位（16 KB）而非紧凑的 512 B。
在本作品的资源占比（BRAM 0.73%）下，这一取舍换取了单拍置位与简单的双口时序。

### 2.3 工作流程

1. 宿主把对象图写入 DDR 0x1E000000，写 OBJ_BASE、OBJ_COUNT、ROOT_LIST。
2. 驱动写 CTRL 启动标记；PL 清位图，装载根集，开始遍历。
3. 引擎按“取头、读引用、置位、入队”循环，直到队列为空且脏边 FIFO 为空。
4. 置 DONE，PS 读 MARKED、位图与 free-list，决定回收。

增量模式下，脏边 FIFO 作为第二工作源参与同一循环：未标记的 ID 置位并计数，已标记的 ID
强制重扫但不重复计数。

### 2.4 AXI 读时序

读通道固定为单拍传输：ARSIZE=3（8 字节）、ARLEN=0、ARBURST=INCR，地址 8 字节对齐。
引用使用 ID=0，对象头使用 ID=1；同 ID 保序、异 ID 互不阻塞。启动与中止时清空两组
FIFO，逐拍丢弃在途响应，直到在途计数归零且 ARVALID 落下后才接受新命令。

【图 2-2 待补：读流水线时序图（命令入队、数据返回、启动清理三种情形）；本地已生成。】

## 3. 软硬划分、接口与寄存器

### 3.1 划分原则

| 部分 | 实现 | 理由 |
|---|---|---|
| 对象图构建、根集管理、回收决策 | PS 软件（C 驱动 / Python 绑定） | 需要与宿主语言和分配器交互，变化频繁 |
| 标记遍历、位图置位、空闲扫描 | PL | 访存密集，指令简单，可并行发起多笔读 |
| 增量屏障记录 | PS 推送，PL 消费 | 记录由 mutator 产生，消费与遍历同源 |

### 3.2 未采用 PYNQ 与 DMA 的说明

本作品直接使用 RTL 加自研驱动，不采用 PYNQ overlay：

- 对象图常驻 DDR，PS 侧通过 /dev/mem 以非缓存映射访问，PL 通过 AXI HP 直接读取；
  overlay 封装不会改变这条数据通路，反而增加一层与测量无关的抽象。
- 标记引擎的关键指标是每对象周期数与 DDR 往返次数，直接控制寄存器与 AXI 读通道才能
  定位优化点。
- 环境与流程可复现；镜像本身非位级可复现（gzip 时间戳），因此以功能、时序与资产哈希
  三方核对，而不承诺 image.ub 的字节一致。

同样未封装 AXI DMA：本设计没有 DMA IP，PL 作为主控直接读 DDR；缓存一致性通过“图驻留
DDR、PS 侧非缓存映射、PL 直接读”规避，而不是在驱动里做 cache 维护。

### 3.3 存储布局

```
obj_base + k*16:    +0  uint32 obj_id
                    +4  uint32 ref_count
                    +8  uint32 ref_addr
                    +12 uint32 reserved

ref_addr:           [ref0][ref1]...[0xFFFFFFFF]
```

图区在设备树中标记为 no-map 保留内存（0x1E000000，1 MiB），避免内核把该区间当作普通
内存管理。

### 3.4 寄存器接口

控制与状态寄存器位于 0x43C00000。完整映射见仓库 README；本节只列与设计相关的部分。

| 偏移 | 名称 | 说明 |
|---|---|---|
| 0x00 | CTRL | [0] start · [2] clear_q · [3] abort · [4] bm_keep · [5] dirty_flush（预置）· [31] done；写时高 12 位必须为 0xA50 |
| 0x04 / 0x08 / 0x0C | OBJ_BASE / OBJ_COUNT / ROOT_COUNT | 图参数，写入后回读校验 |
| 0x10 / 0x14 | MARKED / CYCLES | 标记数与硬件周期 |
| 0x20 | STATUS | 队列溢出、AXI 读错误、引用失步、坏对象头、引擎空闲、扫描忙 |
| 0x24 / 0x28 | BM_ADDR / BM_DATA | 位图探针，写地址后 2 拍读数据 |
| 0x440 | DIRTY_PUSH | 写 0xA5400000，tag 左移 12 位后与 id 按位或；读回当前 FIFO 占用 |
| 0x444 | DIRTY_STAT | 占用、溢出、待处理、最后接受的 tag 与 id |

### 3.5 中断链路

done 信号接到 IRQ_F2P[0]（GIC 中断 ID 61），仅用于验证中断通路：加载模块后写 arm，
运行一次标记，读 /dev/fogccc_irq 可看到触发计数。产品路径仍是轮询 DONE。

## 4. 优化流程与前后对比

### 4.1 四步优化

| # | 手段 | 效果 |
|---|---|---|
| 1 | 多笔未完成读：命令 FIFO 加数据 FIFO 的读命令队列 | 每对象从 2+ref_count 次串行往返降到 2 次并发往返 |
| 2 | 引用阶段压入与取回交错，对象头投机预取 | 两次往返中一次被下一对象的头读覆盖，每对象只暴露一次完整延迟 |
| 3 | 逐引用快路径：位图改为读写地址独立的双口 BRAM | 每次引用 6 拍降到 2 拍 |
| 4 | 引用流水：独立 issuer，描述符提前入队，对象头走独立 AXI 流 | 每对象 38.3 拍降到 17.5 拍；延迟扫描斜率 1.00 降到 0.71 |

表中 38.3 与 17.5 来自同一张图的 Ver3/Ver4 中间步骤；15.4 与 15.2 分别来自 Ver4 历史图
与当前 8 轮扫描，三者口径不同，只用于说明优化方向。

### 4.2 版本对比

| 指标 | Ver1 单笔未完成读 | Ver2 多笔读加快路径 | Ver3 预取加竞态修复 | Ver4 引用流水加六项修复 |
|---|---|---|---|---|
| 判定 | 8/8 | 8/8 | 8/8 | 8/8 |
| 总硬件周期 | 1,804,791 | 557,091 | 484,034 | 240,007 |
| 活跃对象合计 | 约 20,010 | 14,441 | 12,449 | 13,497 |
| 每对象周期 | 90.2 | 38.6 | 38.9 | 15.4 |

各列来自不同随机图，只有“每对象周期”可直接比较；Ver1–Ver4 无归档日志与资源报告，标注为
历史数据。当前版本（v4.13 镜像，与 v4.12 相同）实测：8 轮共 170,932 拍、9,103 个活跃
对象，扣除每轮 4096 拍清位图后为 15.2 拍/对象，相对 Ver1 提升 5.9 倍。

### 4.3 资源与时序

| 项目 | 已发布构建 | 占比 | 本机重建 |
|---|---|---|---|
| LUT | 26,826 | 9.67% | 27,192 |
| FF | 71,460 | 12.88% | 71,466 |
| BRAM | 5.5 块（36Kb） | 0.73% | 5.5 块 |
| DSP | 0 | 0% | 0 |
| WNS / WHS | +0.049 ns / +0.049 ns | — | +0.049 ns |

已发布构建的位流 md5 为 6D4792448135C3796E3CAA1AD86EEA30；本机重建为 965B0A2C…，两次
布局不同导致资源相差不到 1.5%，不影响结论。原始报告（utilization_synth、
utilization_placed、timing_summary_routed）见 vivado/reports/；vivado/fogccc_proj/ 不入库，
可由 build.tcl 重建。

### 4.4 同图四路对比

同一张图依次执行 FPGA、C 未缓存、C 缓存、Python 四种实现，4000 对象结果如下。

| 实现 | 时间 | 每对象 | 相对 FPGA |
|---|---|---|---|
| FPGA 标记引擎 | 645.4 µs | 171 ns | — |
| C，逐条读 DDR（未缓存） | 2038.3 µs | 541 ns | 3.2 倍慢 |
| C，数据驻留 cache | 619.1 µs | 164 ns | 1.0 倍 |
| Python 脚本 BFS | 142.787 ms | 37.9 µs | 221 倍慢 |

每对象时间以已标记的 3766 个对象为分母；若按 4000 个对象计，FPGA 为 161 ns。
Python 列是 py_bfs.py 逐条读 /dev/mem 的实现；4.4 节末端到端成本中的 43.8 ms 是
fpga_vs_python.py 内置 oracle 在另一组 8 轮图上的平均值，两者实现与数据集不同。

适用条件：图驻留 DDR、每次依赖读都是一次内存往返时，硬件占优；图能驻留 cache 时，
FPGA/CPU 时间比为 0.5–1.0，即缓存命中时 CPU 不慢于 FPGA，该场景不应卸载。

端到端成本：构图与写 DDR 102.2 ms、脚本 BFS 43.8 ms、硬件标记 0.214 ms（每图平均），
构图约为标记时间的 478 倍。当前版本的收益在标记阶段，构图仍由 Python 完成。

【图 4-1 待补：每对象周期随版本变化曲线；本地已生成。】

## 5. 大模型协作记录

开发过程使用编码助手参与实现、重构与审查，人负责验收口径、上板实测与发布决策。协作约束
写在仓库 AGENTS.md：每次改动给出验证命令与结果，禁止用编译或综合代替验证，禁止为通过而
放宽测试。

| 项目 | 内容 |
|---|---|
| 模型名称 | DeepSeek V4.1 Flash 1017 |
| 模型版本 | 1017（provider：deepseek；model ID：deepseek-flash） |
| 接入方式 | OpenCode 编码智能体，通过会话工具调用模型；命令与文件操作在本机执行 |
| 使用时间 | 2026-10，主要会话 10-24 至 10-28 |
| 记录范围 | 案例摘要、提示词原文节选、人工修正与验证证据；完整对话保存在本地，不入库 |

记录文件 report/llm-collaboration.md 收录 12 个案例，其中 6 个来自 RTL 与主机代码：

| 案例 | 结论 |
|---|---|
| 换图时在途读串到下一轮 | 指针重装、FIFO 弹出、flush 退出属同一竞态，三处都要门控 |
| 命令 FIFO 同拍入队与出队 | 脉冲信号要同时检查生产侧与消费侧 |
| 位图探针写后立即读 | 带延迟的只读寄存器要把等待写进访问函数 |
| 队列满时静默丢对象 | 正常负载到不了的错误分支只能靠注入覆盖 |
| 屏障校验把哨兵当已标记 | 哨兵值要显式分支，不能依赖真值规则 |
| 全量标记漏发脏集 flush | 跨进程保留的硬件队列要在每轮启动时清空 |

模型不参与板上断电上电、发布资产选择与分支策略；相关决定与证据由人确认。

## 6. 技能包提炼

按指南 3.3.5.2 的类别整理，目录为 skill/，共 9 个条目：

| 类别 | 内容 | 适用场景 | 失效条件 |
|---|---|---|---|
| 故障清单 | 16 条：RTL 竞争、报告读错、构建产物、板级部署 | 任意 Zynq-7000 + Vivado/PetaLinux 工程 | 换成突发读或 HLS 接口后，读引擎相关条目失效 |
| 写作规范 | 技术文档的措辞、结构、数字可追溯要求 | 任意工程文档 | 宣传类材料可放宽措辞，数字仍须可追溯 |
| 回归与负控模板 | 注入方式、必须失败的信号、边界矩阵、恢复步骤 | 任意回归测试 | 纯统计类测试没有负控，需在结论说明 |
| 校验脚本 | check_release.py、vivado_summary.py、verify_bootbin.py | 发布校验、报告汇总、BOOT.BIN 结构比对 | 脚本只做静态校验，不替代上板 |
| 报告与数据模板 | report-outline.md、test-log.md | 设计报告骨架、板测日志头 | 换赛道需改章节；无版本化产物时退化为 commit 加日期 |
| 提示词工作流 | 软硬件划分与瓶颈定位 | 任意软硬件协同选题 | 输出是草案，结论必须由人复核并在板上验证 |

已验证：check_release 对四个发布资产全部一致；vivado_summary 读出与本报告一致的数据；
verify_bootbin 对相同输入拒绝通过（负控），本项目 v4.5/v4.6 重打包时通过。

PYNQ 通用 Skill 未提供，这是主动取舍：本作品不走 overlay 路线，若写成 Skill 将没有在本
项目验证过的效果。迁移到 PYNQ 需要三步：用 .hwh 生成 overlay、用 register_map 封装本文
寄存器、保留非缓存映射或改用 DMA；该路径未在本项目实测，因此只作为后续工作记录，不计入
技能包。

## 7. 复现说明

### 7.1 环境

| 项目 | 版本 |
|---|---|
| 开发板 | OpenSoc OS-ZYNQ7100 Lite（XC7Z100），1 GB DDR3 |
| 器件 | Zynq-7000 XC7Z100FFG900-2 |
| 工具链 | Vivado 2026.1、PetaLinux 2026.1 |
| PS 频率 / 控制台 | 800 MHz / UART0（MIO 14–15），CH340，921600 8N1 |
| 板卡存储 | BOOT 分区（FAT32，约 512 MB）+ USERDATA 分区（FAT32） |

### 7.2 从零构建位流

```bash
vivado -mode batch -source vivado/build.tcl
```

产物：vivado/fogccc_proj/system.xsa、.../impl_1/system_wrapper.bit。综合与实现报告可复制到
vivado/reports/，本仓库附有本机重建的三份原始报告。

### 7.3 从零构建镜像

前置：PetaLinux 2026.1 安装在 ~/xilinx/petalinux；厂商 FSBL 放到 artifacts/zynq_fsbl.elf；
lf r42 的静态 ARM 二进制从上游 lf-linux-arm.tar.gz 解出，放到
petalinux/project-spec/meta-user/recipes-core/images/files/lf（5.6 MB，不入库；缺文件时
rootfs 后处理会报错停止）。

```bash
wsl -e bash petalinux/build_fogccc2.sh
```

脚本会创建 ~/xilinx/fogccc2_linux，套用 petalinux/project-spec/ 的手工配置与中断驱动
recipe，执行 petalinux-config --get-hw-description、petalinux-build 与 petalinux-package
boot，产物复制到 artifacts/。首次构建约 1–3 小时。

FSBL 必须使用厂商版本（其 ps7_init 与板卡 DDR/MIO 匹配）；用 PetaLinux 自带的 FSBL 也能
启动，但 BOOT.BIN 哈希不同，不能用于核对发布资产。镜像构建受 gzip 时间戳影响，image.ub
非位级可复现；以功能、时序与资产哈希核对。

### 7.4 制卡与上电

1. SD 卡分两个 FAT32 分区：BOOT（约 512 MB，卷标 BOOT）与 USERDATA（卷标 USERDATA）。
   Linux 下用 mkfs.vfat；Windows 下用 DiskGenius 或 Rufus。
2. BOOT 根目录放 BOOT.BIN 与 image.ub，并解压 card-boot.zip（boot.scr、uEnv.txt、
   mount_data.sh、system.dtb）。
3. USERDATA 根目录解压 card-userdata.zip（fpga_vs_*.sh、fpga_vs_python.py、bin/、py/、
   tests/、ko/、README.txt）。
4. 插卡上电，串口 921600 8N1；看到 login: 后用 root 登录（空密码）。USERDATA 由 udev
   挂到 /run/media/USERDATA-mmcblk0p2，也可手工挂到 /mnt/userdata。

### 7.5 板上自检

```sh
cd /run/media/USERDATA-mmcblk0p2
sh fpga_vs_c.sh
sh fpga_vs_python.sh 4096 8 2
sh fpga_vs_python_repeat.sh 10
python3 tests/fpga_vs_c_vs_python.py
```

期望：计数对比全部通过；8/8 轮 PASSED (all invariants)；重复性测试 REPEAT_DONE；
四路对比 THREE_WAY_RESULT OK。每项在 logs/ 生成一份带时间戳的日志。

### 7.6 资产与证据

| 资产 | 值 |
|---|---|
| 位流 md5 | 6D4792448135C3796E3CAA1AD86EEA30 |
| BOOT.BIN sha256 | d20530bc3ddbfd01be9cacaeac30618d568b5ec6c180232dab64cf905a3898fd |
| image.ub sha256 | c958eac9970c3a4ddeb333a98922169801b484c706bbd77cf6bc8cbfd29c329f |
| 板测日志 | tools/logs/board_v412_800mhz.log（2026-10-27） |

### 7.7 已知限制

- stop-the-world；未接入运行时，无法与真实应用的停顿时间直接比较。
- 对象上限 4096、图区 1 MiB，超出后需要改位宽与位图规模。
- 时序裕量偏紧（WNS +0.049 ns），后续加逻辑需要重新收敛。
- 本平台每个 store 投递两遍且不保证相邻，协议用命令标记与回执规避；同时携带相同标记与
  (tag,id) 的外来写仍不可区分，属概率事件，由测试覆盖。
- 端到端成本由构图主导，卸载收益集中在标记阶段。

## 附录 A：待补清单

| 位置 | 待补内容 | 状态 |
|---|---|---|
| 封面表 | 队名、队员、学校、年级、指导教师、组别 | 待补（以报名信息为准） |
| 图 2-1 | 系统框图矢量版 | 本地已生成 SVG/PNG，待插入 |
| 图 2-2 | AXI 读流水时序图 | 本地已生成 SVG/PNG，待插入 |
| 图 3-1 | 存储布局与地址空间图 | 本地已生成 SVG/PNG，待插入 |
| 图 4-1 | 每对象周期曲线 | 本地已生成 SVG/PNG，待插入 |
| 图 7-1 | 实测环境照片 | 待拍摄 |
| 附录 C | 致谢 | 待补 |

## 附录 B：参考文献

[1] M. Maas, K. Asanović, J. Kubiatowicz. A Hardware Accelerator for Tracing Garbage
Collection. ISCA 2018, pp. 138–151.

[2] P. Faes, M. Christiaens, D. Buytaert, D. Stroobandt. FPGA-Aware Garbage Collection
in Java. FPL 2005.

[3] C. Ramsay, R. Stewart. Cloaca: A Concurrent Hardware Garbage Collector for Non-strict
Functional Languages. Haskell 2024, pp. 41–54.

[4] D. Detlefs, C. Flood, S. Heller, T. Printezis. Garbage-First Garbage Collection.
ISMM 2004.

[5] D. F. Bacon, P. Cheng, V. T. Rajan. The Metronome: A Simpler Approach to Garbage
Collection in Real-Time Systems. OTM 2003.

[6] Xilinx. Zynq-7000 SoC Technical Reference Manual, UG585.

[7] PYNQ documentation, https://pynq.readthedocs.io/（PYNQ 迁移路径参考，未在本项目实测）

## 附录 C：致谢

【待补】
