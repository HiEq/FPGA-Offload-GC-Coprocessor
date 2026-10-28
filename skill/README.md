# skill/ — 可复用技能包

本目录按《2026 FPGA 赛道选题指南（AMD）》3.3.5.2 组织：把开发过程中沉淀的经验显式写出来，
供**换题目、换板卡**的队伍直接复用。每项都写明适用场景、用法、失效条件，以及在本项目中
实际验证过的效果。

| 目录 | 类型 | 用途 | 适用范围 |
|---|---|---|---|
| pitfalls/rtl-build-board.md | 踩坑清单 | RTL 竞争、报告读错、构建与上板错配的 16 类故障 | 任意 Zynq-7000 + Vivado/PetaLinux 工程 |
| scripts/check_release.py | 校验脚本 | 校验发布资产与 SHA256SUMS 是否一致 | 任意带校验清单的仓库 |
| scripts/vivado_summary.py | 校验脚本 | 从 Vivado 报告提取资源与时序，输出对比表 | 任意 Vivado 工程 |
| scripts/verify_bootbin.py | 校验脚本 | 证明重打包的 BOOT.BIN 只有位流分区变化 | Zynq-7000 bootgen 镜像 |
| templates/report-outline.md | 案例模板 | 符合 3.3.5.3 的设计报告骨架 | 任意参赛作品 |
| templates/test-log.md | 案例模板 | 板测日志头模板（命令/位流/哈希/日期） | 任意板上测试 |
| templates/negative-control.md | 案例模板 | 负控与边界矩阵填写单：注入方式、必须失败的信号 | 任意回归测试 |
| prompts/hw-sw-partition.md | 提示词工作流 | 算法描述 → 软硬件划分；综合报告 → 瓶颈 | 任意软硬件协同选题 |
| pitfalls/doc-style.md | 踩坑清单（写作） | 技术文档的写法约束与常见退回项 | 任意工程文档 |

## 使用方式

```bash
# 校验资产
python3 skill/scripts/check_release.py artifacts/

# 汇总 Vivado 报告（资源 + 时序）
python3 skill/scripts/vivado_summary.py \
    vivado/fogccc_proj/.../system_wrapper_utilization_placed.rpt \
    vivado/fogccc_proj/.../system_wrapper_timing_summary_routed.rpt

# 校验重打包的 BOOT.BIN（新/参考镜像 + 新/参考位流）
python3 skill/scripts/verify_bootbin.py new/BOOT.BIN ref/BOOT.BIN \
    new/system_wrapper.bit ref/system_wrapper.bit
```

## 已验证效果（本项目，2026-10）

- check_release.py：对 v4.13 的 4 个资产 + SHA256SUMS.release 逐一校验，全部一致；
  人为改一位哈希后退出码为 1。
- vivado_summary.py：从本机重建报告读出 LUT 27,192 / FF 71,466 / BRAM 5.5 / DSP 0 与
  WNS +0.049 / WHS +0.049；docs/build.md 记录的是已发布构建（LUT 26,826 / FF 71,460），
  两者相差不到 1.5%，差异来自布局不同。
- verify_bootbin.py：本项目 v4.5/v4.6 重打包后的 BOOT.BIN 与参考镜像比较，改动全部落在位流
  窗口内，通过；负控（新位流未替换）报 images are identical。
- pitfalls/ 的条目全部来自本项目真实故障（AGENTS.md 的缺陷记录与本地调试过程），
  每条都保留了当时的判别信号。
- 三个模板在 docs/releases.md、tools/logs/ 与各测试脚本的实际产出中成型。

## 逐项失效条件

- rtl-build-board.md：第 4–9 条针对单拍、单时钟域、12 位 ID 的读引擎；换成突发读或 HLS 接口后失效。
- doc-style.md：面向技术评审材料；海报类宣传稿可放宽措辞，但数字仍须可追溯。
- check_release.py：只比对清单与文件，不判断资产能否启动。
- vivado_summary.py：依赖报告表头与列序，Vivado 改版后需重跑一次核对。
- verify_bootbin.py：只证明分区结构；位流是否可用仍由上板测试决定。默认保护区按 Zynq-7000
  布局设定，换器件或换 bootgen 配方时用 --head/--tail 调整。
- report-outline.md：按本赛道 3.3.5.3 编写，换赛道需改章节。
- test-log.md：要求位流与镜像哈希；没有版本化产物的项目只能退化为 commit + 日期。
- negative-control.md：适用于可注入故障的测试；纯数据统计类测试没有负控，需在结论里说明。
- hw-sw-partition.md：输出是草案，缺少实测数据时不能作为划分结论。

## 边界（不适用的情况）

- 本包面向 **Zynq-7000 + PetaLinux/sysvinit + 串口控制台** 的组合；Versal、PYNQ 镜像、
  纯 HLS 流程中的部分条目（如 inittab 波特率、boot.scr 行为）不适用。
- scripts/ 只做静态校验，不替代上板测试；时序是否收敛以 Vivado 报告为准。
- 提示词工作流的输出是**草案**，软硬件划分结论必须由人复核并在板上验证。
