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
        test_fpga             (可选)
        <工程文件>
        <日志 gc_run_*.log>

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
  fogccc.bat         统一控制台(唯一入口)
  log.bat            查看 com5.log
  monitor_com5.ps1   fogccc.bat 的后端
  gc_test.py         板级测试脚本 (同一份也放在 USERDATA)
  com5.log           串口原始日志

【备用工具】(已挪到 ..\build_scripts\fallback\, 需要时再用)
  push_file.ps1      不插卡的备用方案: 通过串口把 gc_test.py 推到板子并运行
  raw_console.ps1    纯裸串口控制台(永远滚动, 不切仪表盘)
    用法:  powershell -ExecutionPolicy Bypass -File ..\build_scripts\fallback\push_file.ps1
