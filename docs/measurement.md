# 测量口径与证据边界

> 主 [`README.md`](../README.md) 的「4. 正确性、性能与测量」只给对比表；本文件解释每个数字的口径、
> 边界与出处。

## 测量口径

- `FPGA us` = `CYCLES` / 100 MHz：**只含引擎时间**，不含构图/写对象头/清队列轮询/驱动 `usleep`。
- `C us`：同一张图、同一套 BFS 的 C 实现，与 FPGA 同阶段，可比。`test_main` 的图在 DDR 内、
  驱动不做 cache 维护，所以这是**未缓存（DDR 逐条读）**口径。
- `C（缓存）`：`cmark` 同一张图数据常驻 cache 时测得；cache 命中时 C 会快过引擎，必须一起报
  （见主 README「对优化 C 的参考对比」表）。
- `py_bfs.py` 是独立的 Python 脚本 BFS（逐条读 `/dev/mem`），量级 **212–282×**，只作上下文，
  不与三方对比表相除。
- 原始记录：`tools/logs/board_test_main.log`、`tools/logs/board_gc_test.log`、`tools/logs/cmark_sweep.log`、
  `tools/logs/board_phase3_test_main.log`；旧 `81640C7C` / `3590FBB5` 的证据仅作历史对照。

## 证据边界

`tools/logs/` 中的日志是命令输出与哈希头；`board_coldboot_20261023.raw.log` 是一次完整启动的串口 transcript
（U-Boot → Linux → `login:`），更早的 P1 日志只有命令输出与哈希头、没有完整 transcript；
每个数字在其日志文件头注明命令、bitstream/BOOT 哈希与日期，引用前先核对哈希；
更早 bitstream 下的 C 基线（如 `board_*_p1_20261021.txt`）与测量位流不可直接比较。

2026-10-23 新增一条**开放**边界：PL 刚配置后的第一批 `DIRTY_PUSH` 写可能被本板的重投递打乱
（AW/W 乱配 ⇒ 伪造或丢失一条记录）。同一份脚本在暖机时是 `occ=4 marked=6`
（`tools/logs/board_phase3_dirty_set.log`），作"重启后第一个测试"时是 `occ=3 marked=2`
（`tools/logs/board_phase3_dirty_set_boot_neg_20261023.log`）；分析与影响面见 AGENTS #20。
引用 dirty 相关数字前先确认日志属于哪一种状态。

## 端到端成本

`FPGA us` 只含引擎时间；构图、写 DDR、AXI-Lite 配置、清队列、轮询都不算。
`gc_test.py 4096 8 2` 在板上实测（2026-10-23，位流 `05AA145D…` / BOOT `4786ce62…`，`tools/logs/board_gc_test.log`）：

| 阶段 | 时间 |
| --- | --- |
| 构图 + 写 DDR（Python 3.12，含 1 MB memset 与引用数组）| **197.7 ms / 图平均** |
| 同图 Python BFS（oracle）| **86.6 ms / 图平均**（8 轮合计 693.07 ms）|
| 硬件标记（引擎）| **0.320 ms / 图平均**（8 轮合计 256,198 拍；对象数 932–3841）|

单次卸载的端到端成本由构图主导：**618×** 标记时间（197.7 / 0.320，当前日志）。
构图走 Python；C 侧的 `fpga_gc_build_graph()` 未单独计时，同样不计入 `FPGA us`。
旧 P1 的 103.7 ms / 0.231 ms / 449× 与旧 `81640C7C` 的 164.0 ms / 0.273 ms / 601× 只作历史对照。