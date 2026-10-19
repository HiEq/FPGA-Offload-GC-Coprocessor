# tools/logs/ —— 证据日志

这里只放 **README / Release 里引用得到的原始输出**，不做流水账。每次发布只保留
「最后一次有效测量」那一份，其余删除（需要时从 git 历史里取，`git log -- tools/logs/`）。

| 文件 | 来源 | 谁引用它 |
| --- | --- | --- |
| `board_benchmark_20261019.txt` | `python/benchmark.py`（板上 CPython `gc.collect()` 基线，10–4000 梯度） | README「测量口径」的整堆/增量拆分 |
| `board_test_main_20261019.txt` | `./bin/test_main`（FPGA / C / CPython 三方表） | README 主表 |
| `board_verify_20261019_153604.log` | `tools/serial_run_gc.ps1`（8/8 回归，209,802 拍 / 11,585 对象） | README 性能表的 Ver4 说明 |
| `cmark_sweep.log` | `tools/tests/run_cmark_sweep.ps1`（72 次参数扫描） | README 的 C 基线表 |
| `cmark_sweep_verify_20261017_124925.log` | 同一轮的原始串口输出（含复跑） | 同上 |

命名约定：

- `board_verify_<YYYYMMDD>_<HHMMSS>.log` —— 板级回归一次一份，**只把最终那份入库**
- `cmark_sweep*.log` —— C 基线扫描
- `board_benchmark_*.txt` —— CPython 基线
- 其它（`hw_program.log`、`serial.log`、`cmark_verify_*.log` …）都是过程日志，默认被
  `.gitignore` 忽略，用完即删。

新增证据日志时要同时做两件事：在 `.gitignore` 里加白名单（现有三条按前缀放行），
并在引用它的文档里写清楚 **命令 + 提交 + 日期**（AGENTS.md §4.8.1）。
