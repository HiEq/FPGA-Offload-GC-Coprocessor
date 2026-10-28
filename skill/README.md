# skill/ — 可复用技能包

本目录按《2026 FPGA 赛道选题指南（AMD）》3.3.5.2 组织：把开发过程中沉淀的经验显式写出来，
供**换题目、换板卡**的队伍直接复用。每项都写明适用场景、用法、失效条件，以及在本项目中
实际验证过的效果。

| 目录 | 类型 | 用途 | 适用范围 |
|---|---|---|---|
| `pitfalls/board-bringup.md` | 踩坑清单 | 上板 bring-up 的 12 类典型故障与判别方法 | 任意 Zynq-7000 + PetaLinux 工程 |
| `scripts/check_release.py` | 校验脚本 | 校验发布资产与 `SHA256SUMS` 是否一致 | 任意带校验清单的仓库 |
| `scripts/vivado_summary.py` | 校验脚本 | 从 Vivado 报告提取资源与时序，输出对比表 | 任意 Vivado 工程 |
| `templates/report-outline.md` | 案例模板 | 符合 3.3.5.3 的设计报告骨架 | 任意参赛作品 |
| `templates/test-log.md` | 案例模板 | 板测日志头模板（命令/位流/哈希/日期） | 任意板上测试 |
| `prompts/hw-sw-partition.md` | 提示词工作流 | 算法描述 → 软硬件划分；综合报告 → 瓶颈 | 任意软硬件协同选题 |
| `pitfalls/doc-style.md` | 踩坑清单（写作） | 技术文档的写法约束与常见退回项 | 任意工程文档 |

## 使用方式

```bash
# 校验资产
python3 skill/scripts/check_release.py artifacts/

# 汇总 Vivado 报告（资源 + 时序）
python3 skill/scripts/vivado_summary.py \
    vivado/fogccc_proj/.../system_wrapper_utilization_placed.rpt \
    vivado/fogccc_proj/.../system_wrapper_timing_summary_routed.rpt
```

## 已验证效果（本项目，2026-10）

- `check_release.py`：对 v4.13 的 4 个资产 + `SHA256SUMS.release` 逐一校验，全部一致；
  人为改一位哈希后退出码为 1。
- `vivado_summary.py`：从本项目实现报告读出 LUT 26,826 / FF 71,460 / BRAM 5.5 / DSP 0 与
  WNS +0.049 / WHS +0.049，与 `docs/build.md` 记载一致。
- `pitfalls/` 的条目全部来自本项目真实故障（AGENTS.md #1–#34 与旧副本的
  `AGENT_NOTES_pitfalls.md`），每条都保留了当时的判别信号。
- 两个模板在 `docs/releases.md` 与 `tools/logs/` 的实际产出中成型。

## 边界（不适用的情况）

- 本包面向 **Zynq-7000 + PetaLinux/sysvinit + 串口控制台** 的组合；Versal、PYNQ 镜像、
  纯 HLS 流程中的部分条目（如 inittab 波特率、boot.scr 行为）不适用。
- `scripts/` 只做静态校验，不替代上板测试；时序是否收敛以 Vivado 报告为准。
- 提示词工作流的输出是**草案**，软硬件划分结论必须由人复核并在板上验证。
