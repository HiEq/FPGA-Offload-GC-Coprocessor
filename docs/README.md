# 详细文档索引

主 [`README.md`](../README.md) 只保留大头信息（简介 / 设计说明 / 数据对比 / 构建平台 / 资源利用）；
口径、证据、历史与操作细节拆分到本目录，并在正文对应小节下以链接嵌入。

| 文件 | 内容 | 下沉自正文 |
| --- | --- | --- |
| [`design-details.md`](design-details.md) | Phase 3A/3B（脏边驱动与增量标记）协议、屏障契约、并发证明、溢出与防护；AXI 流水线清理；中断链路 | §3 设计与接口 |
| [`measurement.md`](measurement.md) | 测量口径、证据边界、原始记录、端到端成本 | 文首 / §4 |
| [`performance-history.md`](performance-history.md) | 版本对比（历史）、提升幅度、优化手段（四步） | §4 |
| [`simulation.md`](simulation.md) | 仿真回归用例矩阵与反向验证 | §4 |
| [`board-usage.md`](board-usage.md) | Windows 侧快捷指令、板上测试命令速查、常见问题 | §2 / §5 |

> 原则不变：每个数字都要有命令、哈希与日期，溯源写在 `tools/logs/` 的文件头；
> 本目录只做解释与展开，不引入新的未验证数字。