FOGCCC 串口控制台 —— 使用说明
================================================================

【入口】
  fogccc.bat    统一控制台
                  - 开机阶段显示 FSBL / U-Boot / 内核滚动日志
                  - 进入 shell 后切换为仪表盘：TASK / CPU0 / CPU1 / MEM / TEMP
                  - 键盘输入直通板子，可登录并执行命令
  log.bat       打开 logs\serial.log，串口原始输出，追加写入

串口独占：同一时刻只能有一个窗口占用 COM 口。

----------------------------------------------------------------
【TF 卡分区】
  p1  FAT32  卷标 BOOT      启动文件
  p2  FAT32  卷标 USERDATA  工程文件 / 测试脚本 / 日志

  BOOT 分区
        BOOT.BIN / image.ub / boot.scr / mount_data.sh

  USERDATA 分区
        run_gc.sh / run_cmark.sh / run_repeat.sh / gc_test.py / cmark
        bin/test_main
        tests/  py/  ko/
        logs/gc_run_*.log

  USERDATA 必须为 FAT32，不是 exFAT。
  Windows 无法创建 >32GB 的 FAT32，可在板上格式化：
        mkfs.vfat -F 32 -n USERDATA /dev/mmcblk0p2

----------------------------------------------------------------
【上板流程】
  1. 双击 fogccc.bat，板子上电前启动
  2. 板子上电，等待 linux login:
  3. 登录 root，密码为空
  4. 挂载并运行：
        mkdir -p /mnt/userdata
        mount /dev/mmcblk0p2 /mnt/userdata
        sh /mnt/userdata/run_gc.sh
     指定规模：
        sh /mnt/userdata/run_gc.sh 2048 5 3     # maxN trials avg_refs
  5. 结果输出到窗口，同时写入 USERDATA 的 logs/gc_run_*.log

【通过标准】
  每轮 verdict = OK；汇总 "PASSED (all invariants): 8/8"

【本目录文件】
  入口
    fogccc.bat          统一控制台
    serial_run_gc.ps1   性能基准：串口执行 gc_test 并解析结果
  基础设施
    monitor_com5.ps1    控制台后端
    log.bat             查看串口日志
    serial_cmd.ps1      串口发送命令并抓取输出
    logs\               脚本日志输出，已加入 .gitignore
  tests\
    gc_test.py          板级测试，与卡上 run_gc.sh 同一份
    irq_drv_test.sh     中断端到端验证，验收级
    run_cmark_sweep.ps1 72 次参数扫描，C 基线数据来源
  debug\
    hw_program.tcl      JTAG 烧比特流
    hw_probe.tcl        JTAG 器件探测
    gic_dump.py         GIC 寄存器只读探针
    gic_irq_test.py     GIC SPI 探测
    irq_loss_test.sh    中断计数诊断
