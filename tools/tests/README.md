# tools/tests/ —— 功能测试

跑性能基准只用根目录的 `../serial_run_gc.ps1`。这里放的是**功能性验证**脚本，
都需要板子在跑、串口空闲；日志统一写到 `tools/logs/`。
（纯调试工具在 `../debug/`，不要混在这一层。）

| 脚本 | 类型 | 用途 |
|---|---|---|
| `gc_test.py` | 功能 + 性能（板级） | 卡上 `run_gc.sh` 调用的同一份；打印 seed，`--seed N` 可复现 |
| `irq_drv_test.sh` | 功能（验收级） | 中断端到端：`done` → GIC SPI 61 → 内核 handler |
| `run_cmark_sweep.ps1` | 数据来源 | 72 次参数扫描，README 里 C 基线数据的出处 |

## 用法

```powershell
# 中断验证（脚本已经在卡上，不需要从这里拷）
#   板上：sh /run/media/USERDATA-mmcblk0p2/tests/irq_drv_test.sh

# C 基线扫描
powershell -ExecutionPolicy Bypass -File .\tools\tests\run_cmark_sweep.ps1
```

> 卡上 `USERDATA` 的 `tests/` 是给板子用的另一套（`irq_drv_test.sh`、`py_mark.py`），
> 两份不要互相覆盖。
