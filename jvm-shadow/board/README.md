# FOGCCC 板端工具（USERDATA 持久目录）

安装位置：`/run/media/USERDATA-mmcblk0p2/fogccc-tools/`，在 TF 卡上，
重启不丢。`/tmp` 是指向 `/var/volatile/tmp` 的 tmpfs，重启即清空。

| 文件 | 用途 |
| --- | --- |
| run_1m.sh | 1M 结点 G1M（3 次 GC，COLD+verify） |
| run_workload.sh | 可配置图 FogcccWorkload |
| run_dacapo.sh | 单个 DaCapo 基准（hw/sw） |
| dacapo_quick.sh | 4 个 DaCapo 基准的快速回归（约 75 秒） |
| *.java / *.class | 自研负载源码与编译产物 |

## 安装

PC 侧（仓库根目录）逐文件推送，每条都会比对 md5：

```powershell
powershell -ExecutionPolicy Bypass -File tools\serial_push_chunked.ps1 `
    -Src jvm-shadow\board\run_1m.sh `
    -Dest /run/media/USERDATA-mmcblk0p2/fogccc-tools/run_1m.sh -ChunkKB 4
```

`run_workload.sh`、`run_dacapo.sh`、`README.md`、`tools/dacapo_quick.sh`
和 `jvm-shadow/test/*.java` 用同样的方式推送。然后在板上编译并刷盘：

```sh
T=/run/media/USERDATA-mmcblk0p2/fogccc-tools
cd $T
/run/media/USERDATA-mmcblk0p2/jvm/zulu8/bin/javac -d . *.java
chmod +x $T/*.sh
sync
```

重刷脚本或 class 后必须 `sync`：FAT 分区在未刷盘时断电会留下损坏的簇链。

## 指令

```sh
T=/run/media/USERDATA-mmcblk0p2/fogccc-tools

sh $T/run_1m.sh                 # 1M 结点
sh $T/run_1m.sh 500000          # 指定结点数
sh $T/run_workload.sh 1000000 2 # 结点数 / 平均出边
sh $T/run_dacapo.sh luindex     # 单个基准，硬件侧
sh $T/run_dacapo.sh luindex sw  # 原版 JVM 对照
sh $T/dacapo_quick.sh           # 4 个基准，硬件 + 对照，约 75 秒
```

日志：单基准输出到当前终端；dacapo_quick.sh 写到
/run/media/USERDATA-mmcblk0p2/fogccc-logs/quick/。

## 判读

```sh
grep 'PASSED in' 日志           # 端到端
grep 'verify_extra' 日志        # 必须为 0
grep 'takeover timing us' 日志  # mark / import / clear 分解
grep 'stw:' 日志               # 每次 GC 的 STW 停顿
```
