# tools/tests/ —— 功能测试与调试

**跑性能基准只要用根目录的 `../serial_run_gc.ps1`。** 这里放的是功能性验证和调试脚本，
都需要板子在跑、串口空闲；日志统一写到 `tools/logs/`。

| 脚本 | 类型 | 用途 |
|---|---|---|
| `gc_test.py` | 功能 + 性能（板级） | 卡上 `run_gc.sh` 调用的同一份；打印 seed，`--seed N` 可复现 |
| `irq_drv_test.sh` | 功能（验收级） | 中断端到端：`done` → GIC SPI 61 → 内核 handler |
| `irq_loss_test.sh` | 诊断 | 中断计数与合并行为（脚本自称非验收测试） |
| `gic_dump.py` | 调试 | GIC 寄存器只读探针 |
| `gic_irq_test.py` | 调试 | GIC SPI 61 的使能/挂起位探测 |
| `hw_program.tcl` | 调试 | JTAG 烧比特流（不用拔卡、不用重启） |
| `hw_probe.tcl` | 调试 | JTAG 器件探测 |
| `run_cmark_sweep.ps1` | 数据来源 | 72 次参数扫描，README 里 C 基线数据的出处 |

## 用法

```powershell
# 烧比特流
D:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat -mode batch `
    -source tools\tests\hw_program.tcl -tclargs vivado\fogccc_proj\...\system_wrapper.bit
```

```sh
# 板上跑中断验证（脚本已经在卡上，不需要从这里拷）
sh /run/media/USERDATA-mmcblk0p2/tests/irq_drv_test.sh
```

> 卡上 `USERDATA` 里有一份同样用途的子集（`tests/irq_drv_test.sh`、`py_mark.py`），
> 那是给板子用的，不要和这里的宿主脚本混在一起。
