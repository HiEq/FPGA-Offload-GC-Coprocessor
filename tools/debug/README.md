# tools/debug/ —— 调试工具

**不参与验收**。性能基准在 `../serial_run_gc.ps1`，功能测试在 `../tests/`。
这里的工具只用于**定位问题**（看寄存器、看中断、烧比特流）。

| 脚本 | 用途 |
|---|---|
| `hw_program.tcl` | JTAG 烧比特流（不拔卡、不重启，换 PL 最快的方式） |
| `hw_probe.tcl` | JTAG 器件探测（确认 cable 和 xc7z100 在不在） |
| `gic_dump.py` | GIC 寄存器只读探针（`0xF8F01000` 一带） |
| `gic_irq_test.py` | GIC SPI 61 的使能/挂起位探测 |
| `irq_loss_test.sh` | 中断计数与合并行为（脚本自称非验收测试） |

## 用法

```powershell
# 烧比特流
D:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat -mode batch `
    -source tools\debug\hw_program.tcl `
    -tclargs vivado\fogccc_proj\fogccc_z7100.runs\impl_1\system_wrapper.bit
```

```sh
# 板上跑中断诊断（脚本在卡上 /run/media/USERDATA-mmcblk0p2/tests/）
cd /run/media/USERDATA-mmcblk0p2
D=. sh tests/irq_drv_test.sh
```

## 判据提醒

- `hw_program.tcl` 成功只代表**烧写完成**，不代表设计正确 —— 之后仍要跑 `tests/` 或基准
- `gic_*` 只读，不会改状态；`irq_loss_test.sh` 会 `insmod/rmmod`
