# artifacts/ —— 上卡文件

卡上有两个分区，文件按分区放置，拷贝时不要混：

## 本目录（根） → BOOT 分区

FAT32、卷标 `BOOT`、约 512 MB。板子由 FSBL 读这里启动。

| 文件 | 说明 |
|---|---|
| `BOOT.BIN` | FSBL + 比特流 + U-Boot（18.6 MB） |
| `image.ub` | 内核 + 设备树 + initramfs（43.2 MB） |
| `boot.scr` / `uEnv.txt` | U-Boot 启动脚本与默认环境 |
| `system.dtb` | 设备树（与 image.ub 内的一致，便于单独排查） |
| `zynq_fsbl.elf` | 厂商 FSBL 原始 ELF（BOOT.BIN 的组成部分） |
| `mount_data.sh` | 板上把两个分区挂到 `/mnt/boot`、`/mnt/userdata` |

## `userdata/` → USERDATA 分区

FAT32、卷标 `USERDATA`。板子起来后挂到 `/run/media/USERDATA-mmcblk0p2`。

| 路径 | 说明 |
|---|---|
| `run_gc.sh` | GC 测试入口（需要同级 `gc_test.py`） |
| `run_cmark.sh` | C 基线入口（需要同级 `cmark` / `cmark.c`） |
| `run_repeat.sh` | 重复测量（组 1/2/3） |
| `gc_test.py` | GC 测试主体，`--seed` 可复现 |
| `cmark` | C 基线二进制（动态链接，板上 glibc 同版本） |
| `README.txt` | 卡上的目录说明（拷到 USERDATA 根） |
| `bin/test_main` | 板级 C 测试套件 |
| `ko/fogccc-irq.ko` | IRQ_F2P[0] 内核模块（由 PetaLinux 构建产出，**不入库**） |
| `tests/irq_drv_test.sh` | 中断驱动端到端验证（板上唯一保留的测试脚本） |
| `tests/py_mark.py` | CPython 基准，`test_main` 用 popen 调用它 |

日志不进本目录：`run_gc.sh` 会写到卡上的 `logs/`。

以下**不放进卡**，只留在仓库：

| 文件 | 原因 |
|---|---|
| `csrc/cmark.c` | 板上没有 gcc，源码放卡上永远编不了 |
| `tools/gic_dump.py`、`tools/gic_irq_test.py` | GIC 诊断，JTAG 可直接读同样寄存器 |
| `tools/irq_loss_test.sh` | 脚本自己注明是诊断、非验收测试 |

## 注意

- USERDATA 必须 FAT32，**不要 exFAT**（内核未启用）。
- `image.ub` 不是位级可复现的（gzip 时间戳），只能靠功能验证。
