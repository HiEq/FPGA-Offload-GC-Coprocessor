# 构建环境与仓库布局

主 [`README.md`](../README.md) 只保留构建入口；平台规格、工具链、资源与时序、目录说明放在这里。

## 平台

| 项目 | 规格 |
| --- | --- |
| FPGA | Xilinx Zynq-7000 XC7Z100FFG900-2 |
| LUT / FF | 277,400 CLB LUT / 554,800 CLB FF |
| BRAM / DSP | 755 × 36Kb / 2,020 slices |
| PS | 2× ARM Cortex-A9 @ 800 MHz（v4.8 起；v4.7 及以前 666.67 MHz），DDR3 @ 533.33 MHz |
| 工具链 | Vivado 2026.1 / PetaLinux 2026.1 |
| 时钟域 | 单一时钟 FCLK0 = 100 MHz（引擎 / AXI-Lite / AXI HP），无 CDC |
| AXI HP | 64-bit，每拍 1 个 32-bit 字，8 字节对齐 + 半字选择 |
| 实测资源 | LUT 26,826 (9.67%) / FF 71,460 (12.88%) / BRAM 5.5 (0.73%) / DSP 0 |
| 时序 | WNS +0.049 ns / WHS +0.049 ns（v4.5 起未再重建 PL，裕量偏紧） |

资源与时序取自 `vivado/build.tcl` 的实现报告（位流 md5 `6D4792448135C3796E3CAA1AD86EEA30`，2026-10-25），v4.6–v4.12 未重建 PL，数值不变。`fogccc_proj/` 不入库，可由该脚本重建。

## 工具链版本

| 组件 | 版本 |
| --- | --- |
| Vivado | 2026.1（SW Build 6511674） |
| PetaLinux | 2026.1（SDK `release-S06060014`） |
| 交叉编译器 | gcc 13.4.0（`arm-amd-linux-gnueabi-gcc`，`-mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard`） |
| 构建主机 | Ubuntu 22.04.5 LTS（WSL2） |
| 目标 glibc | 2.39 |
| 目标内核 / U-Boot | linux-xlnx 6.18.10 / u-boot-xlnx 2026.01 |
| 目标 Python | 3.12.12（仅标准库） |

## 构建

```bash
# 位流
cd vivado && vivado -mode batch -source build.tcl
# 产物: fogccc_proj/fogccc_z7100.runs/impl_1/system_wrapper.bit

# 板上二进制（PC）
SDK_ENV=<sdk> ./csrc/build_c_bins.sh    # test_main / libfogccc.so
powershell -File tools/make_manifest.ps1
```

约束：

1. 用 SDK 的 `environment-setup-cortexa9t2hf-neon-amd-linux-gnueabi`，调用 `$CC`；不要用根
   `Makefile` 的 `CROSS=arm-linux-gnueabihf-`（PetaLinux 2026.1 SDK 提供的是 `arm-amd-linux-gnueabi-gcc`）。
2. 产物须为 ARM：`file libfogccc.so` 含 `ARM, EABI5`。
3. SDK sysroot 与发布镜像同为 glibc 2.39。
4. Python 只用标准库（`ctypes`、`mmap`、`struct`、`time`、`random`、`sys`）。

`tools/vivado_affinity.ps1` 可在构建期间调整 Vivado 子进程的 CPU 亲和性与优先级；按命令行里的
运行目录识别 synth/place/route 阶段，vivado 退出后自行结束。

## 目录

```
rtl/          gc_top / gc_regs / gc_mark_engine / gc_bitmap / gc_queue /
              gc_freelist / gc_dirty_fifo / gc_axi_read
sim/          tb_gc_top、定向 TB（axi_read / runstart / cmdfifo / regs_aww / hand-over）、
              axi_proto_check.v、run_*.bat|sh
csrc/         fpga_gc.[ch]、test_main.c、py_bfs.py、build_c_bins.sh
python/       fogccc.py（ctypes 绑定）
vivado/       build.tcl（BD + 综合 + 实现 + XSA）、build_rtl_only.tcl
tools/        serial_*.ps1、push_tests.ps1、make_manifest/card/release_*、
              reproduce_all.ps1、tests/（板上测试）、debug/（调试脚本）、logs/（证据）
driver/       fogccc_irq.c + PetaLinux 模块 recipe
petalinux/    工程骨架与构建脚本（BUILD_GUIDE.md）
artifacts/    卡上产物、SHA256SUMS（二进制清单）
skill/        技能包（pitfalls / scripts / templates / prompts）
docs/         构建、上板、测量、仿真、性能历史、设计细节
tests/        仓库契约测试（目录、提交信息、字面量基线）
.github/      CI（lint：语法 + iverilog 定向回归 + gcc + SHA256SUMS）
Makefile      常用命令入口
AGENTS.md     AI 参与者的工程约束
```

与选题指南 3.3.5.4 推荐目录的对照见 [`README.md`](../README.md) 第 6 节。

`artifacts/BOOT.BIN` 与 `artifacts/image.ub` 被 `.gitignore` 排除，只随 Release 发布。
