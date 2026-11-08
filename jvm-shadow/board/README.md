# FOGCCC 板端脚本（USERDATA 持久目录）

安装位置：`/run/media/USERDATA-mmcblk0p2/fogccc-tools/`，在 TF 卡上，
重启不丢。`/tmp` 是指向 `/var/volatile/tmp` 的 tmpfs，重启即清空。

| 文件 | 用途 |
| --- | --- |
| selftest.sh | 自研负载全套（G1M、FogcccWorkload、Tree、Mutate、Threads、Hello），结束时一张表 |
| dacapo_bench.sh | 4 个 DaCapo 基准，硬件与对照，结束时一张表 |
| run_dacapo.sh | 单个 DaCapo 基准（hw/sw），输出直接看终端 |
| *.java / *.class | 自研负载源码与编译产物 |

## 安装

PC 侧（仓库根目录）逐文件推送，每条都会比对 md5：

```powershell
$src = 'jvm-shadow\board'
foreach ($f in 'selftest.sh','dacapo_bench.sh','run_dacapo.sh','README.md') {
    powershell -ExecutionPolicy Bypass -File tools\serial_push_chunked.ps1 `
        -Src "$src\$f" -Dest "/run/media/USERDATA-mmcblk0p2/fogccc-tools/$f" -ChunkKB 4
}
```

`jvm-shadow/test/*.java` 同样推送。然后在板上编译并刷盘：

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

sh $T/selftest.sh              # 自研负载全套，约 35 秒
sh $T/selftest.sh 500000       # 指定结点数
sh $T/dacapo_bench.sh          # 4 个 DaCapo 基准，约 100 秒
sh $T/run_dacapo.sh luindex    # 单个基准，硬件侧
sh $T/run_dacapo.sh luindex sw # 单个基准，原版对照
```

两个脚本运行中每步打印一行进度（终端下是进度条 + 已用秒数），结束时
打印一张表，退出码 0 表示全部通过。日志写到
`/run/media/USERDATA-mmcblk0p2/fogccc-logs/{selftest,quick}/`。

## 判读

| 列 | 含义 |
| --- | --- |
| result | PASS / FALLBACK / TIMEOUT / FAIL |
| e2e_ms | 端到端毫秒（G1M 与 DaCapo 是 3 次 GC 或单次运行） |
| mark_ms | 纯标记毫秒；硬件取 takeover 的中位数，原版取 GC Mark 的中位数 |
| extra | 硬件侧 verify_extra，必须为 0 |
| e2e_x | 仅 DaCapo 表：端到端 原版 / 硬件（约 1.0；硬件接管有固定开销） |
| mark_x | 仅 DaCapo 表：纯 mark 原版 / 硬件 |

`FALLBACK` 表示对象数超过 1,048,576 的 id 上限，该轮回退 CPU 标记。

## 重新编译

```sh
cd /run/media/USERDATA-mmcblk0p2/fogccc-tools
/run/media/USERDATA-mmcblk0p2/jvm/zulu8/bin/javac -d . *.java
```
