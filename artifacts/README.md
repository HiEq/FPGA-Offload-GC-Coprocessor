# artifacts/ —— 上卡文件

卡上分两个分区，文件按分区放置，不要混放。

## 根目录 → BOOT 分区

FAT32，卷标 `BOOT`，约 512 MB。板子由 FSBL 从该分区启动。

| 文件 | 大小 | 说明 |
|---|---|---|
| `BOOT.BIN` | 18.6 MB | FSBL + 比特流 + U-Boot |
| `image.ub` | 43.2 MB | 内核 + 设备树 + initramfs |
| `boot.scr` / `uEnv.txt` | — | U-Boot 启动脚本与默认环境 |
| `system.dtb` | 18 KB | 设备树，与 `image.ub` 内的一致 |
| `zynq_fsbl.elf` | 347 KB | 厂商 FSBL 原始 ELF，`BOOT.BIN` 的组成部分 |
| `mount_data.sh` | 1.2 KB | 板上把两个分区挂到 `/mnt/boot`、`/mnt/userdata` |

## `userdata/` → USERDATA 分区

FAT32，卷标 `USERDATA`。板子启动后挂载于 `/run/media/USERDATA-mmcblk0p2`。

| 路径 | 说明 |
|---|---|
| `run_gc.sh` | GC 测试入口，需同级 `gc_test.py` |
| `run_cmark.sh` | C 基线入口，需同级 `cmark` |
| `run_repeat.sh` | 重复测量 |
| `gc_test.py` | GC 测试主体，`--seed` 可复现 |
| `cmark` | C 基线二进制，动态链接 |
| `README.txt` | 卡上目录说明 |
| `bin/test_main` | 板级 C 测试套件 |
| `ko/fogccc-irq.ko` | IRQ_F2P[0] 内核模块，由 PetaLinux 构建产出，不入库 |
| `tests/irq_drv_test.sh` | 中断驱动端到端验证 |
| `tests/py_mark.py` | CPython 基准，`test_main` 经 popen 调用 |
| `py/fogccc.py` + `py/libfogccc.so` | Python ctypes 绑定，含 STATUS 与位图探针 |

日志不在本目录，`run_gc.sh` 写入卡上 `logs/`。

以下文件只留在仓库，不放入卡：

| 文件 | 原因 |
|---|---|
| `csrc/cmark.c` | 板上无 gcc，无法编译 |
| `tools/gic_dump.py`、`tools/gic_irq_test.py` | GIC 诊断，可用 JTAG 读取同样寄存器 |
| `tools/irq_loss_test.sh` | 诊断用途，非验收 |

## 注意

- USERDATA 必须为 FAT32；内核未启用 exFAT。
- `image.ub` 非位级可复现（gzip 时间戳），以功能验证为准。
