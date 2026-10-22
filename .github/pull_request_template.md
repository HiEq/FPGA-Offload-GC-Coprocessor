## 做了什么

<!-- 一段话。关联的 issue：Fixes #<n> -->

## 验证

verified: <命令 + 结果；或"仅静态检查，见下">
coverage: <命令 + 数字 | not measured>
unverified: <没测什么、为什么>

## 风险

<!-- 静默失败候选：位宽截断、指针回绕、握手反压、缓存一致性…… -->

## 检查清单

- [ ] 只有一件事；RTL / 文档 / 格式化没有混在一起
- [ ] 改了寄存器、STATUS 位或设计参数：`csrc/fpga_gc.h`、`rtl/gc_regs.v`、README 三处一致
- [ ] 新测试能在实现被破坏时失败（反向验证跑过，不是"看起来能挂"）
- [ ] 新字面量已命名（`#define`/`parameter`/`const`）或加了 `allow-hardcoded: <理由>`；没有随手改大 `tests/hardcoded_baseline.txt`
- [ ] 新增测量数字带 command + commit + hash + date，或标注 `historical/unverified`
- [ ] CI 不绿的项都写进了 `unverified:`
