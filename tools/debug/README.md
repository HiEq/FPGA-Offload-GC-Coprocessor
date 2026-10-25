# tools/debug/ —— 调试工具

不参与验收。性能基准见 `../serial_run_gc.ps1`，功能测试见 `../tests/`。

| 脚本 | 用途 |
|---|---|
| `hw_program.tcl` | JTAG 烧比特流，无需拔卡或重启 |
| `hw_probe.tcl` | JTAG 器件探测 |
| `gic_dump.py` | GIC 寄存器只读探针（`0xF8F01000`） |
| `gic_irq_test.py` | GIC SPI 61 使能/挂起位探测 |
| `irq_loss_test.sh` | 中断计数与合并行为，非验收测试 |
| `diag_run.ps1` | 经串口跑一条命令并等到 sentinel（其余板级调试脚本的底座） |
| `run_phase3_board.ps1` | 阶段 3 板级验收链（脏集 / 并发 / 溢出 / 残留 / 防护 + 收尾查脏 FIFO 为空） |
| `diag_freelist.py` | free-list 位图与计数的板级诊断 |
| `dirty_probe.py` | `DIRTY_PUSH` 的 2× 计数（store 重投递）测量探针 |
| `verify_bootbin.py` | `BOOT.BIN` 结构性校验（定位 FSBL / bitstream / U-Boot 段） |
| `serial_capture_boot.ps1` | 抓取一次上电启动的完整串口记录 |
| `serial_coldboot_verify.ps1` | 冷启动后登录并核对环境（BOOT.BIN 哈希 / mount / no-map / FPGA 状态 / `test_main`） |

> 一次性脚本用完即退库：`diag_gctest_trial.py`（某次 `gc_test` stall 定位）已移除，结论记在
> `tools/logs/` 与 `AGENTS.md` 的对应条目。

## 用法

```powershell
D:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat -mode batch `
    -source tools\debug\hw_program.tcl `
    -tclargs vivado\fogccc_proj\fogccc_z7100.runs\impl_1\system_wrapper.bit
```

```sh
cd /run/media/USERDATA-mmcblk0p2
D=. sh tests/irq_drv_test.sh
```

## 判据

- `hw_program.tcl` 成功只表示烧写完成，不代表设计正确；完成后仍需跑 `tests/` 或基准
- `gic_*` 只读，不改变状态；`irq_loss_test.sh` 会 `insmod/rmmod`
