# tools/tests/ —— 功能测试

性能基准入口为 `../serial_run_gc.ps1`。本目录只放功能性验证脚本。
运行条件：板子在运行，串口空闲。日志写入 `tools/logs/`。调试工具见 `../debug/`。

| 脚本 | 类型 | 用途 |
|---|---|---|
| `gc_test.py` | 功能 + 性能（板级） | 卡上 `run_gc.sh` 调用的同一份；`--seed N` 可复现 |
| `irq_drv_test.sh` | 功能（验收级） | 中断端到端：`done` → GIC SPI 61 → 内核 handler |
| `run_cmark_sweep.ps1` | 数据采集 | 72 次参数扫描，C 基线数据来源 |

## 用法

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\tests\run_cmark_sweep.ps1
```

板上运行：脚本自带的默认 `D` 就是 `/run/media/USERDATA-mmcblk0p2`，从该目录跑正好命中——`sh tests/irq_drv_test.sh`；
如果数据分区挂在 `/mnt/userdata`，要显式传：`D=/mnt/userdata sh tests/irq_drv_test.sh`。

> 卡上 `USERDATA/tests/` 是板级脚本（`irq_drv_test.sh`、`py_mark.py`），与本目录为两份，不要互相覆盖。
