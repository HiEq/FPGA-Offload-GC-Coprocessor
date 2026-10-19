# tools/tests/ —— 功能测试

性能基准入口为 `../serial_run_gc.ps1`。本目录只放功能性验证脚本。
运行条件：板子在运行，串口空闲。日志写入 `tools/logs/`。调试工具见 `../debug/`。

| 脚本 | 类型 | 用途 |
|---|---|---|
| `gc_test.py` | 功能 + 性能（板级） | 卡上 `run_gc.sh` 调用的同一份；`--seed N` 可复现 |
| `irq_drv_test.sh` | 功能（验收级） | 中断端到端：`done` → GIC SPI 61 → 内核 handler |
| `run_cmark_sweep.ps1` | 数据采集 | 72 次参数扫描，C 基线数据来源 |
| `abort_test.py` | 功能（板级） | `CTRL[3]` abort：T1 基线 / T2 控制组（不写 abort 必须跑完）/ T3 abort 后 `DONE` 必须始终为 0 / T4 同图恢复 / T5 **换一张不同规模的图**（危险路径：上一轮残留会被多标） |
| `done_race_test.py` | 功能（板级） | `START` 是 posted write 的 stale-DONE 竞态（AGENTS gap 9）+ 连续换图跑（P3 用驱动同样的"读回 + `usleep(1)` + 轮询"顺序，每轮必须返回本轮自己的 `L`） |

## 用法

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\tests\run_cmark_sweep.ps1
```

板上运行：脚本自带的默认 `D` 就是 `/run/media/USERDATA-mmcblk0p2`，从该目录跑正好命中——`sh tests/irq_drv_test.sh`；
如果数据分区挂在 `/mnt/userdata`，要显式传：`D=/mnt/userdata sh tests/irq_drv_test.sh`。

> 卡上 `USERDATA/tests/` 里的同名文件由 `make card` 从本目录**生成**；不要手改卡上那份（会被覆盖）。
