# tools/logs/ —— 证据日志

这里只放 **README / Release 引用得到的最终一次测量**，不做流水账。每次发布只保留
「最后一次有效测量」那一份，其余删除（需要时从 git 历史里取，`git log -- tools/logs/`）。

每个文件头部四行是溯源信息：

```
# command: <完整命令>
# bitstream: <md5>   boot.bin: <md5>
# commit: <产生这些二进制的源码提交>
# date: <YYYY-MM-DD>
```

二进制本身的哈希见 `artifacts/SHA256SUMS`（随卡二进制）和 `artifacts/SHA256SUMS.release`
（Release 资产）。

| 文件 | 来源 | 谁引用它 |
| --- | --- | --- |
| `board_test_main_20261020.txt` | `./bin/test_main`（4/4）| README 主表 |
| `board_gc_test_20261020.txt` | `sh run_gc.sh 4096 8 2`（8/8）| README 的 8/8 结论 |
| `board_test_main_v41_20261020.txt` | v4.1 镜像 JTAG 加载的 `./bin/test_main`（4/4）| AGENTS #16 |
| `board_coldboot_test_main_v41_20261020.txt` | 从 v4.1 `BOOT.BIN` 冷启动的 `./bin/test_main`（4/4）| AGENTS #16 |
| `board_coldboot_abort_v41_20261020.txt` | 冷启动 `tests/abort_test.py`（T1–T5）| AGENTS #16 |
| `board_coldboot_sweep_v41_20261020.txt` | 冷启动 `tests/abort_sweep.py`（11/11）| AGENTS #16 |
| `board_coldboot_race_v41_20261020.txt` | 冷启动 `tests/done_race_test.py`（P3 20/20）| AGENTS #16 |
| `board_coldboot_run_gc_v41_20261020.txt` | 冷启动 `sh run_gc.sh 4096 8 2`（8/8）| AGENTS #16 |
| `board_test_main_p1_20261021.txt` | 新镜像 `./bin/test_main`（4/4）| README / AGENTS #17 |
| `board_gc_test_p1_20261021.txt` | 新镜像 `sh run_gc.sh 4096 8 2`（8/8）| README / AGENTS #17 |
| `board_abort_test_p1_20261021.txt` | 新镜像 `tests/abort_test.py`（T1–T5）| AGENTS #17 |
| `board_abort_sweep_p1_20261021.txt` | 新镜像 `tests/abort_sweep.py`（11/11）| AGENTS #17 |
| `board_done_race_p1_20261021.txt` | 新镜像 `tests/done_race_test.py`（P3 20/20）| AGENTS #17 |
| `board_benchmark_20261020.txt` | `python3 benchmark.py`（CPython `gc.collect()` 10–4000 梯度）| README「测量口径」 |
| `board_coldboot_20261020.log` | 从发布 `BOOT.BIN` 冷启动的串口记录 + `md5sum` + `abort_sweep` | README Release 说明 |
| `cmark_sweep.log` | `tools/tests/run_cmark_sweep.ps1`（72 次参数扫描）| README 的 C 基线表 |
| `board_irq_20261020.txt` | `D=/mnt/userdata sh tests/irq_drv_test.sh`（PL 刚配置）| README「中断链路」 |
| `xsim_20261020.log` | `sim\run_sim.bat` 的完整 xsim 输出（含 T-STAR）| README「仿真回归」 |

命名约定：

- `board_test_main_<YYYYMMDD>.txt` —— `test_main` 的完整输出（4 项测试 + 汇总）
- `board_gc_test_<YYYYMMDD>.txt` —— `run_gc.sh` 的完整输出（`PASSED n/n` + 周期数）
- `board_benchmark_<YYYYMMDD>.txt` —— `benchmark.py` 的 CPython 基线梯度
- `board_coldboot_<YYYYMMDD>.log` —— 从发布 `BOOT.BIN` 冷启动的串口记录
- `xsim_<YYYYMMDD>.log` —— `sim\run_sim.bat` 的完整输出
- 其它（`hw_program.log`、`serial.log`、`*_verify_*.log` …）都是过程日志，默认被
  `.gitignore` 忽略，用完即删。

串口日志保留原始行宽与换行；导出工具的 ANSI 控制符、提示符回显、`mount` 前导行会被
剔除，并在文件头注明，数据行不改。

新增证据日志时要同时做两件事：在 `.gitignore` 里加白名单，并在引用它的文档里写清楚
**命令 + 提交 + 日期**（AGENTS.md §4.8.1）。
