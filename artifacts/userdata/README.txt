FOGCCC USERDATA 分区说明
================================================================

根目录 = 入口脚本 + 它们的直接依赖（脚本用 dirname 找同级文件）
  run_gc.sh        主测试入口        （需要同级 gc_test.py）
  run_cmark.sh     C 基线入口        （需要同级 cmark）
  run_repeat.sh    重复测量           （调用上面两个）
  gc_test.py       GC 测试主体        （--seed 可复现）
  cmark            C 基线二进制       （交叉编译，动态链接）

bin/
  test_main        板级 C 测试套件    （正确性 / 周期图 / 100 次重复一致性）

ko/
  fogccc-irq.ko    IRQ_F2P[0] 内核模块（只给 tests/irq_drv_test.sh 用）

tests/
  irq_drv_test.sh  中断驱动端到端验证（板上唯一保留的测试脚本）

logs/
  gc_run_*.log     run_gc.sh 的输出（tee 自动写到 logs/）

----------------------------------------------------------------
不在这张卡上的东西
  cmark.c           源码在仓库 csrc/cmark.c，板上没有 gcc 用不到
  诊断脚本          gic_dump.py / gic_irq_test.py / irq_loss_test.sh
                    已移到仓库 tools/，需要时再拷过来；
                    同样的 GIC 寄存器信息也可以用 JTAG 直接读

常用命令（板上）
  cd /run/media/USERDATA-mmcblk0p2
  sh run_gc.sh 4096 8 2           GC 8 次试验（默认参数）
  sh run_cmark.sh 4096 8 2        C 基线
  sh run_repeat.sh 10             重复测量（组 1/2/3）
  ./bin/test_main                 板级 C 测试套件（需 root）
  insmod ko/fogccc-irq.ko         加载中断模块
  sh tests/irq_drv_test.sh        中断端到端验证

日志统一在 logs/，脚本和二进制不再与日志混放。
