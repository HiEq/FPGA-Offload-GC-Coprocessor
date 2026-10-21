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
| `board_test_main_20261020.txt` | 旧 81640 基线 / boot `074CF12D` 的 `./bin/test_main`（4/4）| 历史对照（README 不再当主表） |
| `board_gc_test_20261020.txt` | 旧 81640 基线 / boot `074CF12D` 的 `sh run_gc.sh 4096 8 2`（8/8，218,429 拍）| 历史对照（README 不再当 8/8 主证据） |
| `board_test_main_v41_20261020.txt` | v4.1 旧镜像 JTAG 加载的 `./bin/test_main`（4/4）| AGENTS #16 |
| `board_coldboot_test_main_v41_20261020.txt` | 从 v4.1 旧 `BOOT.BIN` 冷启动的 `./bin/test_main`（4/4）| AGENTS #16 |
| `board_coldboot_abort_v41_20261020.txt` | 冷启动 `tests/abort_test.py`（T1–T5）| AGENTS #16 |
| `board_coldboot_sweep_v41_20261020.txt` | 冷启动 `tests/abort_sweep.py`（11/11）| AGENTS #16 |
| `board_coldboot_race_v41_20261020.txt` | 冷启动 `tests/done_race_test.py`（P3 20/20）| AGENTS #16 |
| `board_coldboot_run_gc_v41_20261020.txt` | 冷启动 `sh run_gc.sh 4096 8 2`（8/8）| AGENTS #16 |
| `board_test_main_p1_20261021.txt` | **当前** P1 镜像 `3590FBB5` / boot `7487463a` 的 `./bin/test_main`（4/4）| README 主表 / AGENTS #17 |
| `board_gc_test_p1_20261021.txt` | **当前** P1 镜像 `sh run_gc.sh 4096 8 2`（8/8，184,767 拍）| README 的 8/8 结论 / AGENTS #17 |
| `board_abort_test_p1_20261021.txt` | 当前 P1 镜像 `tests/abort_test.py`（T1–T5）| AGENTS #17 |
| `board_abort_sweep_p1_20261021.txt` | 当前 P1 镜像 `tests/abort_sweep.py`（11/11）| AGENTS #17 |
| `board_done_race_p1_20261021.txt` | 当前 P1 镜像 `tests/done_race_test.py`（P3 20/20）| AGENTS #17 |
| `board_run_gc_20261020.txt` | 早一轮 `run_gc.sh` 的完整输出（历史对照，未进入主表）| 历史对照 |
| `board_benchmark_20261020.txt` | `python3 benchmark.py`（CPython `gc.collect()` 10–4000 梯度；bitstream `02D52FCC`）| README「测量口径」 |
| `board_coldboot_20261020.log` | 旧发布 `BOOT.BIN` 冷启动的 U-Boot/Linux 串口记录；只有启动段，**不含** `md5sum` / `abort_sweep` | README Release 说明 |
| `cmark_sweep.log` | `tools/tests/run_cmark_sweep.ps1`（72 次参数扫描，bitstream `02D52FCC`）| README 的 C 基线表 |
| `board_irq_20261020.txt` | `D=/mnt/userdata sh tests/irq_drv_test.sh`（PL 刚配置）| README「中断链路」 |
| `xsim_20261020.log` | `sim\run_sim.bat` 的 xsim 输出（只跑 `tb_gc_top`，含 T-STAR）| README「仿真回归」 |

> **冷启动证据边界**：2026-10-21 P1 的五份 `board_*_p1_20261021.txt` 是命令输出与哈希头，
> **不是完整串口 transcript**；P1 冷启动的完整 transcript 没有归档。`board_coldboot_20261020.log`
> 是旧 81640 基线的启动段，不能用来证明 P1 冷启动。
> 旧基线有两套 boot 标识：`board_test_main_20261020` / `board_gc_test_20261020` 是 md5
> `074CF12D`；`board_coldboot_*_v41_20261020` 是 SHA256 `6874fb55…`。
>
> **P1 未重跑 cmark / benchmark 边界**：`cmark_sweep.log` 与 `board_benchmark_20261020.txt`
> 来自 bitstream `02D52FCC` / commit `5a21a7c`，不能当作 `3590FBB5` 的证据。

命名约定：

- `board_test_main_<YYYYMMDD>.txt` —— `test_main` 的完整输出（4 项测试 + 汇总）
- `board_gc_test_<YYYYMMDD>.txt` —— `run_gc.sh` 的完整输出（`PASSED n/n` + 周期数）
- `board_benchmark_<YYYYMMDD>.txt` —— `benchmark.py` 的 CPython 基线梯度
- `board_coldboot_<YYYYMMDD>.log` —— 从发布 `BOOT.BIN` 冷启动的串口记录（启动段）
- `board_coldboot_<suite>_v41_<YYYYMMDD>.txt` —— 冷启动后单项测试的命令输出（含哈希头）
- `xsim_<YYYYMMDD>.log` —— `sim\run_sim.bat` 的完整输出（只覆盖 `tb_gc_top`）
- 其它（`hw_program.log`、`serial.log`、`*_verify_*.log` …）都是过程日志，默认被
  `.gitignore` 忽略，用完即删。

串口日志保留原始行宽与换行；导出工具的 ANSI 控制符、提示符回显、`mount` 前导行会被
剔除，并在文件头注明，数据行不改。

新增证据日志时要同时做两件事：在 `.gitignore` 里加白名单，并在引用它的文档里写清楚
**命令 + 提交 + 日期**（AGENTS.md §4.8.1）。
