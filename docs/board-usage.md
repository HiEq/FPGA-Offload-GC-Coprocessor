# 上板操作：Windows 快捷指令与板上测试速查

> 主 [`README.md`](../README.md) 的「2. 快速开始」「5. 发布与上板」只保留构建与烧录要点；
> 日常操作细节放在这里。

## Windows 侧快捷指令

串口脚本自动识别 CH340；多根串口线时用 `-Port COMx` 指定。

| 做什么 | 命令 | 说明 |
| --- | --- | --- |
| 板子控制台 | 双击 `tools\fogccc.bat` | 开机日志 → 登录 shell，键盘直通板子；进入 shell 后自动用宿主时间发一次 `date -s` |
| 看串口日志 | `tools\log.bat` | 追加查看 `tools\logs\serial.log` |
| 运行 GC 基准 | `powershell -ExecutionPolicy Bypass -File tools\serial_run_gc.ps1` | 自动登录 root（先试空密码，不行再试 `root`）、挂载 `/mnt/userdata`、跑 `run_gc.sh`；必须同时看到 `PASSED (all invariants): n/n` 和 `RUN_GC_RC=0` 才算 PASS（最长约 7 分钟）|
| 切回 FOGCCC 系统 | `... tools\serial_switch_to_fogccc.ps1` | 卡上还有 Arch Linux 系统；若当前停在 Arch 的 `zynq7100 login:`，本脚本用 root/root 登录后 `touch /boot/use-fogccc` 并重启进 FOGCCC |
| 大文件推送 | `... tools\serial_push_chunked.ps1 -Src <file> -Dest <path>` | 关回显 + 按提示符同步 + 分块 + 每块 md5；115200 下 18 MB 约 35 分钟 |
| 大文件续传 | `... tools\serial_push_resume.ps1 -Src <file> -Dest <path>` | 每块落到卡上 `parts/`，记录进度；掉线/断电后重跑同一条命令从断点继续（43 MB 的 `image.ub` 用这条，约 90 分钟）|
| 二进制清单 | `... tools\make_manifest.ps1` | 重新生成 `artifacts/SHA256SUMS`；CI 用 `-Check` 防止二进制改了清单没更新 |
| 刷新卡上副本 | `... tools\make_card.ps1` | 把 `tools/tests/`、`python/`、`csrc/` 里的脚本同步到 `artifacts/userdata/`（不动二进制）|
| 同步卡上测试（整批）| `... tools\push_tests.ps1` | 把仓库 `tools/tests/` 整批推到卡上 **`tests/`**（发布 zip 的布局）；只推单个文件、或卡上残留第二份副本，都会让 `import` 落到旧模块/旧版本而误报 |
| C 基准参数扫描 | `powershell -ExecutionPolicy Bypass -File tools\tests\run_cmark_sweep.ps1` | 72 次参数扫描，性能表里 C 基线数据的来源 |
| 单条命令 | `powershell -ExecutionPolicy Bypass -File tools\serial_cmd.ps1 -Cmd "uname -a"` | 发一条命令并抓回显 |
| 指定串口 | 上面任意一条加 `-Port COM7` | 只在自动识别失败（多根串口线）时才需要 |

> 串口是**独占**的：同一时刻只能有一个窗口占用 COM 口。跑脚本前先关掉 `fogccc.bat`，
> 否则会报“拒绝访问/端口被占用”。

> 板上**没有 RTC、也没有网络**，所以每次上电时钟都退回 2018-03-09。`fogccc.bat` 和
> `serial_run_gc.ps1` 会用宿主时间自动发一次 `date -s`（只在 shell 提示符、控制台空闲时发），
> 卡上日志的时间戳因此是真实日期；不想被自动设置就加 `-NoTimeSync`。

## 板上测试命令速查

数据分区 p2 的开机挂载点取决于镜像：本镜像（stock `/etc/fstab` 里**没有** p2 条目）由 udev 挂到
`/run/media/USERDATA-mmcblk0p2`；**`/mnt/userdata` 需要自己挂**（`sh /mnt/boot/mount_data.sh`，
主机脚本 `serial_run_gc.ps1` / `run_cmark_sweep.ps1` / `serial_push_resume.ps1` 也会 `mkdir` + `mount`）。
两条路径是同一个分区，固定用一个即可。下面命令里的 `<datadir>` 用实际挂载的那条，也可以让脚本自己探测：

```sh
D=$(for d in /run/media/USERDATA-mmcblk0p2 /mnt/userdata; do [ -d "$d/tests" ] && echo $d && break; done)
```

以下命令均需 root。

### 1. 中断通路验证

```sh
D=/run/media/USERDATA-mmcblk0p2 sh "$D/tests/irq_drv_test.sh"
```

插驱动 → arm → 跑一次 GC → 读计数 → 卸载。期望末行：

```
VERDICT: IRQ_DRIVEN_DONE_OK  (before='0 1' after='<N> 0')
```

### 2. GC 主测试（FPGA vs Python 参照）

```sh
sh run_gc.sh                 # 默认 maxN=4096 trials=8 avg_refs=2
sh run_gc.sh 512 2 1         # 小规模快速验证
sh run_gc.sh 2048 5 3
```

| 参数 | 含义 | 默认 |
|---|---|---|
| `maxN` | 每轮对象数上限（硬件上限 4096）| 4096 |
| `trials` | 随机轮数 | 8 |
| `avg_refs` | 平均额外出度 | 2 |

期望：`PASSED (all invariants): trials/trials`，并打印相对同一进程内 Python BFS 参照的加速比。

### 3. 三方对比（FPGA / C 未缓存 / Python 脚本）

```sh
cd /mnt/userdata
./bin/test_main
```

`test_main` 直接读器件并跑图，不需要额外脚本；需要 root。

输出与判读见主 README「三方对比（FPGA / C 未缓存 / Python 脚本）」与 [`measurement.md`](measurement.md)。

与另外两条命令的分工：`test_main` 是**主对比**（FPGA vs 同图 C BFS）；`run_gc.sh` 跑可靠性 +
对照它自己的 Python BFS；`run_cmark.sh` 只比 FPGA vs C（未缓存 / cache 两种口径）。

### 4. C 基准（FPGA vs C）

```sh
sh run_cmark.sh              # 默认 4096 8 2
sh run_cmark.sh 2048 5 3
```

打印 `totals:` 与 `per object:` 两组时间；出现 `MISMATCH` 即失败。

### 5. 重复性测试

```sh
sh run_repeat.sh 10          # 默认 10 次
```

三组：不同种子 vs Python 参照、不同图 vs C、同种子 5 次；末行 `REPEAT_DONE`。

### 6. 单独调用

```sh
python3 gc_test.py 4096 8 2 --seed 12345   # 指定种子可复现
python3 tests/freelist_contract_test.py    # Phase 2 free-list 软件契约负控（A/B/C/D 四段）
python3 tests/dirty_set_test.py            # Phase 3A 脏集（A0/A/B/C/D + D-neg）
python3 tests/dirty_concurrent_test.py     # Phase 3B 并发 mutator + remark（5 轮 + 负控）
python3 tests/dirty_overflow_test.py       # Phase 3A 溢出契约 + 退回全标记
python3 tests/ctrl_spill_test.py           # CTRL 写重投递防护
python3 tests/dirty_api_test.py            # 阶段 3A C 驱动 + ctypes 绑定接口（含 --neg）
python3 tests/dirty_leftover_test.py       # 残留屏障记录 ⇒ 必须 flush
./bin/test_main                            # 4 项 C 测试（需 root）
insmod ko/fogccc-irq.ko                    # 仅插驱动
```

### 7. 结果判读

| 关键行 | 含义 |
|---|---|
| `PASSED (all invariants)` | 功能正确 |
| `CONTRACT_RESULT OK` | free-list 软件契约（扫描中探针 / 早读 / 扫描中重跑）符合文档 |
| `DIRTY_SET_RESULT OK` / `DIRTY_CONCURRENT_RESULT OK` | 脏集/增量标记（含并发 remark）与 CPU oracle 一致 |
| `CTRL_SPILL_RESULT OK` | 卡上位流含 `CTRL` 写重投递防护 |
| `IRQ_DRIVEN_DONE_OK` | 中断通路正常 |
| `REPEAT_DONE` | 重复性测试完成 |
| `MISMATCH` / `FAIL` / `FAILED` | 失败 |

日志：`/mnt/userdata/logs/gc_run_<日期>_<时间>.log`。

### 8. 常见问题

- `insmod: already loaded` → 先 `rmmod fogccc_irq`
- 打不开 `/dev/mem` → 必须是 root
- 没有 `IRQ_DRIVEN_DONE_OK` → 确认 PL 比特流已加载，且测试时 PL 处于 `done=0`（刚上电）
- `run_gc.sh` 找不到 `gc_test.py` → 脚本按自身目录找文件，整个目录要一起放在 `/mnt/userdata`
- `run_cmark.sh` 报找不到 `cmark` → 板上无 gcc，不能现场编译，直接用卡上的可执行文件
- 某个 `tests/*.py` 报 `ModuleNotFoundError`（旧模块名未更新）→ 卡上 `tests/` 是**整套**副本，
  只推了部分文件。用 `tools\push_tests.ps1` 整批同步（`serial_phase2.ps1` 与 `run_phase3_board.ps1` 已内置该步骤）