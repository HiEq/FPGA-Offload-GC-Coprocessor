# tools/logs/ —— 证据日志

这里只放 **README / Release 里引用得到的原始输出**，不做流水账。每次发布只保留
「最后一次有效测量」那一份，其余删除（需要时从 git 历史里取，`git log -- tools/logs/`）。

| 文件 | 来源 | 谁引用它 |
| --- | --- | --- |
| `board_test_main_20261020.txt` | `./bin/test_main`（发布镜像 PetaLinux / Python 3.12.12，FA816025 启动，4/4）| README 主表 |
| `board_gc_test_20261020.txt` | `sh run_gc.sh 4096 8 2`（同一镜像，8/8，211,705 拍）| README 的 8/8 结论 |
| `board_benchmark_20261020.txt` | `python3 benchmark.py`（CPython `gc.collect()` 10–4000 梯度）| README「测量口径」 |
| `board_coldboot_20261020.log` | 从 `BOOT.BIN` `FA816025…` 冷启动的原始串口记录 + `md5sum` + `abort_sweep` | README Release 说明 |
| `xsim_20261019.log` | `sim\run_sim.bat` 的完整 xsim 输出（含 T-MAXFAN / T-ROOTCLAMP）| README「仿真回归」 |
| `cmark_sweep.log` | `tools/tests/run_cmark_sweep.ps1`（72 次参数扫描）| README 的 C 基线表 |
| `cmark_sweep_verify_20261017_124925.log` | 同一轮的原始串口输出（含复跑）| 同上 |

命名约定：

- `board_test_main_<YYYYMMDD>.txt` —— `test_main` 的完整输出（4 项测试 + 汇总）
- `board_gc_test_<YYYYMMDD>.txt` —— `run_gc.sh` 的完整输出（`PASSED n/n` + 周期数）
- `board_benchmark_<YYYYMMDD>.txt` —— `benchmark.py` 的 CPython 基线梯度
- `board_coldboot_<YYYYMMDD>.log` —— 从发布 `BOOT.BIN` 冷启动的原始串口记录
- `xsim_<YYYYMMDD>.log` —— `sim\run_sim.bat` 的完整输出
- 其它（`hw_program.log`、`serial.log`、`*_verify_*.log` …）都是过程日志，默认被
  `.gitignore` 忽略，用完即删。

新增证据日志时要同时做两件事：在 `.gitignore` 里加白名单（现有几条按前缀放行），
并在引用它的文档里写清楚 **命令 + 提交 + 日期**（AGENTS.md §4.8.1）。
