# vivado/reports

Vivado 综合与实现的原始报告副本，供评委核对资源与时序；完整工程
（vivado/fogccc_proj/）不入库，可由 vivado/build.tcl 重建。

| 文件 | 来源 | 内容 |
|---|---|---|
| utilization_synth.rpt | 综合阶段 | LUT / FF / BRAM / DSP 使用量 |
| utilization_placed.rpt | 布局后 | 布局后的资源占用与分布 |
| timing_summary_routed.rpt | 布线后 | WNS / WHS、时钟与路径摘要 |

## 来源与口径

- 工具：Vivado 2026.1
- 构建：2026-10-28 本机重建，产物
  vivado/fogccc_proj/fogccc_z7100.runs/impl_1/system_wrapper.bit
- 位流 md5：965B0A2C43E338408145DB39A807BCB8
- 与已发布构建（位流 md5 6D4792448135C3796E3CAA1AD86EEA30）的差别：布局不同导致
  LUT 27,192 对 26,826、FF 71,466 对 71,460，差异小于 1.5%；时序同为 WNS/WHS +0.049 ns。
- 报告按原文件复制，未改数字；只保留最终实现的三个文件，综合/实现中间报告未收录。
