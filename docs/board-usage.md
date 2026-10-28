# 上板操作：烧录、卡布局、串口与板上测试

## 烧录与卡布局

两个 FAT32 分区，卷标 `BOOT` / `USERDATA`：

| 分区 | 卷标 | 内容 |
|---|---|---|
| p1 | `BOOT` | `BOOT.BIN`、`image.ub`，解压 `card-boot.zip`（`boot.scr` / `uEnv.txt` / `mount_data.sh` / `system.dtb`）|
| p2 | `USERDATA` | 解压 `card-userdata.zip`（`fpga_vs_*.sh` / `fpga_vs_python.py` / `bin/` / `py/` / `tests/` / `ko/`）|

`USERDATA` 必须是 FAT32（内核未编 exFAT）。Windows 图形界面无法创建 >32 GB 的 FAT32，
可用 `mkfs.vfat -F 32 -n USERDATA /dev/mmcblk0p2`。

上电：`linux login:` → `root`（空密码）→ 数据分区由 udev 挂在 `/run/media/USERDATA-mmcblk0p2`。

## Windows 侧快捷指令

串口脚本自动识别 CH340；多根串口线时用 `-Port COMx` 指定。

| 功能 | 命令 | 说明 |
| --- | --- | --- |
| 板卡控制台 | 双击 `tools\fogccc.bat` | 显示开机日志并进入登录 shell，键盘输入直通板卡；进入 shell 后以宿主时间执行一次 `date -s` |
| 查看串口日志 | `tools\log.bat` | 追加查看 `tools\logs\serial.log` |
| 运行 GC 基准测试 | `powershell -ExecutionPolicy Bypass -File tools\serial_fpga_vs_python.ps1` | 自动以 root 登录（先试空密码，再试 `root`）、挂载 `/mnt/userdata`、执行 `fpga_vs_python.sh`；必须同时出现 `PASSED (all invariants): n/n` 与 `RUN_RC=0` 才判定通过（最长约 7 分钟）|
| 分块推送文件 | `... tools\serial_push_chunked.ps1 -Src <file> -Dest <path>` | 关闭回显、按提示符同步、分块传输并逐块校验 md5；逐行经 shell 传输，约 2 KB/s，仅适用于小文件 |
| 断点续传文件 | `... tools\serial_push_resume.ps1 -Src <file> -Dest <path>` | 每个分块写入卡上 `parts/` 并记录进度；掉线或断电后重新执行同一命令即从断点继续（43 MB 的 `image.ub` 约 90 分钟）|
| 生成二进制清单 | `... tools\make_manifest.ps1` | 重新生成 `artifacts/SHA256SUMS`；CI 使用 `-Check` 校验二进制与清单一致 |
| 刷新卡上副本 | `... tools\make_card.ps1` | 将 `tools/tests/`、`python/`、`csrc/` 中的脚本同步到 `artifacts/userdata/`（不涉及二进制）|
| 整批同步卡上测试 | `... tools\push_tests.ps1` | 将仓库 `tools/tests/` 整批推送到卡上 `tests/`（发布 zip 的布局）；仅推单个文件或保留第二份副本会使 `import` 命中旧模块/旧版本，导致误判 |
| 执行单条命令 | `powershell -ExecutionPolicy Bypass -File tools\serial_cmd.ps1 -Cmd "uname -a"` | 发送一条命令并采集回显 |
| 指定串口设备 | 上述任意命令追加 `-Port COM7` | 仅在自动识别失败（多根串口线）时需要 |

串口为独占资源，同一时刻只能有一个窗口占用 COM 口；运行脚本前先关闭 `fogccc.bat`，否则报“拒绝访问/端口被占用”。

板卡无 RTC、无网络，上电后时钟回到 2018-03-09；`fogccc.bat` 与 `serial_fpga_vs_python.ps1` 在 shell 空闲时以宿主时间执行一次 `date -s`（`-NoTimeSync` 可关闭），因此卡上日志的时间戳为真实日期。

## 板上测试命令速查

数据分区 p2 由 udev 挂载到 `/run/media/USERDATA-mmcblk0p2`（stock `/etc/fstab` 无 p2 条目），以下命令先进入该目录：

```sh
cd /run/media/USERDATA-mmcblk0p2
```

`/mnt/userdata` 不是自动挂载点；需要该路径时先执行 `sh /run/media/BOOT-mmcblk0p1/mount_data.sh`（一次挂载 p1 与 p2）。

以下命令均需 root。

### 1. 中断通路验证（本项目不使用，可选）

```sh
D=/run/media/USERDATA-mmcblk0p2 sh "$D/tests/irq_drv_test.sh"
```

加载驱动 → 预置中断 → 执行一次 GC → 读取计数 → 卸载驱动。期望末行：

```
VERDICT: IRQ_DRIVEN_DONE_OK  (before='0 1' after='<N> 0')
```

### 2. FPGA vs Python

```sh
sh fpga_vs_python.sh                 # 默认 maxN=4096 trials=8 avg_refs=2
sh fpga_vs_python.sh 512 2 1         # 小规模快速验证
sh fpga_vs_python.sh 2048 5 3
```

| 参数 | 含义 | 默认 |
|---|---|---|
| `maxN` | 每轮对象数上限（硬件上限 4096）| 4096 |
| `trials` | 随机轮数 | 8 |
| `avg_refs` | 平均额外出度 | 2 |

期望：`PASSED (all invariants): trials/trials`，并输出相对同一进程内 Python BFS 参照的加速比。

### 3. FPGA vs C（同一张图、同一 BFS）

```sh
sh fpga_vs_c.sh            # 运行 bin/test_main 并把输出写入 logs/
```

`fpga_vs_c.sh` 调用 `bin/test_main` 直接访问器件并执行图遍历，只与 C 实现对比计数；需要 root。Python 参照由 `fpga_vs_python.sh`（上节）给出，数据表与测量条件见 [`measurement.md`](measurement.md)。

分工：`test_main` 校验正确性（FPGA 计数 == C）；`fpga_vs_python.sh` 校验可靠性；`fpga_vs_c_vs_python.py` 给出同一张图的性能对比。

### 4. 同一张图的性能对比（FPGA / C 未缓存 / C 缓存 / Python）

```sh
cd /run/media/USERDATA-mmcblk0p2 && python3 tests/fpga_vs_c_vs_python.py
```

同一张图依次执行四种实现，四个标记计数必须相等；末行 THREE_WAY_RESULT OK。
FPGA us 只含引擎时间，C 的时间在 C 内计时，Python 列是量级参照。
数据表见 [measurement.md](measurement.md)。

### 5. 重复性测试

```sh
sh fpga_vs_python_repeat.sh 10          # 默认 10 次
```

两组：不同种子 vs Python 参照、同种子 5 次；末行 `REPEAT_DONE`。

### 6. 单独调用

```sh
python3 fpga_vs_python.py 4096 8 2 --seed 12345   # 指定种子可复现
python3 tests/freelist_contract_test.py    # Phase 2 free-list 软件契约负控（A/B/C/D 四段）
python3 tests/dirty_set_test.py            # Phase 3A 脏集（A0/A/B/C/D + D-neg）
python3 tests/dirty_concurrent_test.py     # Phase 3B 并发 mutator + remark（5 轮 + 负控）
python3 tests/dirty_overflow_test.py       # Phase 3A 溢出契约 + 退回全标记
python3 tests/ctrl_spill_test.py           # CTRL 写重投递防护
python3 tests/dirty_api_test.py            # 阶段 3A C 驱动 + ctypes 绑定接口（含 --neg）
python3 tests/dirty_leftover_test.py       # 残留屏障记录 ⇒ 必须 flush
./bin/test_main                            # 3 项 C 测试（需 root）
insmod ko/fogccc-irq.ko                    # 仅插驱动
```

### 7. 结果判读

| 关键行 | 含义 |
|---|---|
| `PASSED (all invariants)` | 功能正确 |
| `CONTRACT_RESULT OK` | free-list 软件契约（扫描中探针 / 早读 / 扫描中重新执行）符合文档 |
| `DIRTY_SET_RESULT OK` / `DIRTY_CONCURRENT_RESULT OK` | 脏集/增量标记（含并发 remark）与 CPU oracle 一致 |
| `CTRL_SPILL_RESULT OK` | 卡上位流含 `CTRL` 写重投递防护 |
| `IRQ_DRIVEN_DONE_OK` | 中断通路正常 |
| `REPEAT_DONE` | 重复性测试完成 |
| `MISMATCH` / `FAIL` / `FAILED` | 失败 |

日志：`/mnt/userdata/logs/fpga_vs_python_run_<日期>_<时间>.log`。

### 8. 常见问题

- `sh: fpga_vs_python.sh: No such file or directory` → 当前目录不是数据分区；先
  `cd /run/media/USERDATA-mmcblk0p2`，或改用绝对路径
- `./bin/test_main: No such file or directory` → 分区没挂到该路径（`/mnt/userdata` 是空目录）；
  换 `/run/media/USERDATA-mmcblk0p2` 或先执行 `mount_data.sh`
- `insmod: already loaded` → 先 `rmmod fogccc_irq`
- 打不开 `/dev/mem` → 必须是 root
- 没有 `IRQ_DRIVEN_DONE_OK` → 确认 PL 位流已加载，且测试时 PL 处于 `done=0`（刚上电）
- `fpga_vs_python.sh` 找不到 `fpga_vs_python.py` → 脚本按自身目录找文件，整个目录要一起放在 `/mnt/userdata`
- 某个 `tests/*.py` 报 `ModuleNotFoundError`（旧模块名未更新）→ 卡上 `tests/` 是**整套**副本，
  只推了部分文件。用 `tools\push_tests.ps1` 整批同步（`serial_phase2.ps1` 与 `run_phase3_board.ps1` 已内置该步骤）
