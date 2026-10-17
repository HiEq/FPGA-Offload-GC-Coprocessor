FOGCCC 串口控制台  ——  使用说明
================================

【只需要双击这一个】
  fogccc.bat      统一控制台
                    - 开机阶段(FSBL/U-Boot/内核): 普通滚动文字, 看得到启动日志
                    - Linux 起来后(出现 login: 或 shell 提示符): 自动切换成
                      仪表盘; 顶部五条:
                          TASK  当前任务进度(测试脚本上报)
                          CPU0  板子 Zynq 核0 占用
                          CPU1  板子 Zynq 核1 占用
                          MEM   板子内存占用
                          TEMP  板子 SoC 片内温度(XADC)
                    - 键盘输入直通板子, 在这个窗口里登录、敲命令

  log.bat         用记事本打开 com5.log (所有串口原始输出, 追加写入)

【串口是独占的】
  同一时刻只能开一个串口窗口。报 "Failed to open COM5" 就先关掉别的。

--------------------------------------------------------------
【TF 卡分区】
  p1  FAT32   (BOOT)      只放启动文件
  p2  FAT32   卷标 USERDATA  工程文件 / 测试脚本 / 日志

  p1 (BOOT):
        BOOT.BIN
        image.ub
        boot.scr
        mount_data.sh         (可选: 一键挂载两个分区)

  p2 (USERDATA):
        gc_test.py
        run_gc.sh
        bin/test_main         (可选)
        <工程文件>
        logs/gc_run_*.log

  USERDATA 必须是 FAT32(不是 exFAT! 板子内核没编 exFAT).
  Windows 图形界面无法创建 >32GB 的 FAT32, 用板子自己格式化:
        mkfs.vfat -F 32 -n USERDATA /dev/mmcblk0p2

--------------------------------------------------------------
【上板流程 —— 一个窗口搞定】
  1. 双击 fogccc.bat        (板子上电前先开着)
  2. 板子上电               -> 启动日志滚动(raw 阶段)
     出现  linux login:     -> 界面自动切成仪表盘
  3. 登录:  root  + 回车     (空密码, 直接进 root@linux:~#)
  4. 挂载并运行测试:
        mkdir -p /mnt/userdata
        mount /dev/mmcblk0p2 /mnt/userdata
        sh /mnt/userdata/run_gc.sh
     或指定规模:
        sh /mnt/userdata/run_gc.sh 2048 5 3     # maxN trials avg_refs
  5. 结果同时打印到窗口 和 写到 USERDATA 上的 gc_run_*.log

【通过标准】
  每轮 verdict = OK (全部不变式成立),
  汇总 "PASSED (all invariants): 8/8"

【本目录文件】
  只需要这两个入口:
    fogccc.bat          统一控制台(唯一入口)：开串口 + 仪表盘 + 写 logs\serial.log
    serial_run_gc.ps1   性能基准：串口跑 gc_test 并解析结果

  基础设施:
    monitor_com5.ps1    控制台后端
    log.bat             查看串口日志
    serial_cmd.ps1      串口发一条命令并抓输出（自动化的基础件）
    logs\               所有脚本的日志输出 (已 .gitignore)

  tests\                功能测试与调试脚本 (详见 tests\README.md)
    gc_test.py          板级测试（卡上 run_gc.sh 同一份）
    irq_drv_test.sh     中断端到端验证（验收级）
    irq_loss_test.sh    中断计数诊断（非验收）
    gic_dump.py         GIC 寄存器只读探针
    gic_irq_test.py     GIC SPI 探测
    hw_program.tcl      JTAG 烧比特流
    hw_probe.tcl        JTAG 器件探测
    run_cmark_sweep.ps1 72 次参数扫描 (README 里 C 数据的出处)

【已移除】(2026-10-17 清理)
  push_cmark2.ps1 / serial_login.ps1 / serial_verify.ps1 / serial_cmark.ps1
  jtag_probe.tcl / debug_boot.tcl / boot.bif
  原因: 依赖已删除的板上 gcc+base64 / 功能被 serial_cmd.ps1 + serial_run_gc.ps1 覆盖 /
        引用不存在的文件 / 被 hw_probe.tcl 取代。
