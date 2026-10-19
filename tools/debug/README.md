# tools/debug/ —— 调试工具

不参与验收。性能基准见 `../serial_run_gc.ps1`，功能测试见 `../tests/`。

| 脚本 | 用途 |
|---|---|
| `hw_program.tcl` | JTAG 烧比特流，无需拔卡或重启 |
| `hw_probe.tcl` | JTAG 器件探测 |
| `gic_dump.py` | GIC 寄存器只读探针（`0xF8F01000`） |
| `gic_irq_test.py` | GIC SPI 61 使能/挂起位探测 |
| `irq_loss_test.sh` | 中断计数与合并行为，非验收测试 |

## 用法

```powershell
D:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat -mode batch `
    -source tools\debug\hw_program.tcl `
    -tclargs vivado\fogccc_proj\fogccc_z7100.runs\impl_1\system_wrapper.bit
```

```sh
cd /mnt/userdata
D=. sh tests/irq_drv_test.sh
```

## 判据

- `hw_program.tcl` 成功只表示烧写完成，不代表设计正确；完成后仍需跑 `tests/` 或基准
- `gic_*` 只读，不改变状态；`irq_loss_test.sh` 会 `insmod/rmmod`
