# 测量口径与证据

> 主 [`README.md`](../README.md) 只给汇总表；逐组数据、口径与出处在这里。
> 当前证据位流 `3D3A9F1D…` / `BOOT.BIN` `63e52587…`（2026-10-24）。

## 三方对比（`test_main` Test 1）

同一张图、同一个 `avg_refs=3`，FPGA 标记与同一套 BFS 的 C 实现（`fpga_gc_sw_mark`）对比；
C 同时是 `marked` 的独立 oracle。

```
Objects  marked   FPGA us   C us      vs C
10       9        44.0      14.5      0.3x
50       47       48.7      29.8      0.6x
100      96       57.0      58.2      1.0x
500      474      113.6     261.0     2.3x
1000     945      184.7     566.2     3.1x
2000     1882     339.4     1063.3    3.1x
4000     3766     645.8     2145.8    3.3x
```

出处 `tools/logs/board_test_main.log`。`vs C` > 1 表示 FPGA 更快；小图更慢是固定启动开销
（≈4400 拍）。`marked < Objects` 是随机图中从根 0 不可达的对象。

## C 基准（`cmark`，同图同跑）

72 次、4 组参数；三个实现（HW / C 非缓存 / C 缓存）的标记数都等于真值 L。

| 组 | maxN / trials / avg_refs | HW 拍/对象 | C-uncached | C-cached | HW / C-unc | HW / C-cac |
| -- | ------------------------ | ---------- | ---------- | -------- | ---------- | ---------- |
| 1  | 4096 / 24 / 2            | 17.5       | 558 ns     | 166 ns   | 3.2x       | 1.0x       |
| 2  | 4096 / 16 / 4            | 20.2       | 678 ns     | 183 ns   | 3.4x       | 0.9x       |
| 3  | 4096 / 16 / 1            | 17.7       | 491 ns     | 137 ns   | 2.8x       | 0.8x       |
| 4  | 2048 / 16 / 2            | 20.6       | 548 ns     | 141 ns   | 2.7x       | 0.7x       |

出处 `tools/logs/cmark_sweep.log`；命令 `tools/tests/run_cmark_sweep.ps1`。C 侧波动约 ±3%。

### 适用条件

| 图所在位置 | CPU 每次依赖读 | 硬件（AXI HP，非一致） |
|---|---|---|
| DDR（非缓存） | 一次 DDR 往返，无重叠 | 同样往返，8 笔未完成读 + 对象头预取 |
| CPU cache | L1/L2 命中，几纳秒 | 仍走 AXI HP 到 DDR |

硬件只在指针追逐被 DDR 延迟钉住时占优（2.6–3.4×）；图驻留 cache 时为 0.7–1.0×。

## 口径

- `FPGA us` = `CYCLES` / 100 MHz：只含引擎时间，不含构图、写对象头、清队列轮询、驱动 `usleep`。
- `C us`：同图同 BFS 的 C 实现，与引擎同阶段；图在 DDR、驱动不做 cache 维护，即**未缓存**口径。
- `C（缓存）`：`cmark` 中数据常驻 cache 的上限参照，必须与未缓存口径一起报。
- `py_bfs.py`：Python 字节码 BFS（逐条读 `/dev/mem`），只作量级参照（212–282×）。

## 端到端成本

`gc_test.py 4096 8 2`（`tools/logs/board_gc_test.log`）：

| 阶段 | 时间 |
| --- | --- |
| 构图 + 写 DDR（Python 3.12，含 1 MB memset 与引用数组）| 197.7 ms / 图平均 |
| 同图 Python BFS（oracle）| 86.6 ms / 图平均 |
| 硬件标记（引擎）| 0.320 ms / 图平均 |

单次卸载的端到端成本由构图主导（约 618× 标记时间）。构图走 Python；
`fpga_gc_build_graph()` 未单独计时，同样不计入 `FPGA us`。

## 证据边界

`tools/logs/` 中每条日志头部写明命令、位流、BOOT 哈希、提交与日期；引用数字前先核对哈希。
不同位流下的 C 基线不可直接比较。
