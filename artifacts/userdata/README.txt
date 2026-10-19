FOGCCC USERDATA 分区说明
================================================================

根目录：入口脚本及其直接依赖（脚本用 dirname 定位同级文件）
  run_gc.sh         主测试入口，需同级 gc_test.py
  run_cmark.sh      C 基线入口，需同级 cmark
  run_repeat.sh     重复测量，调用以上两个
  gc_test.py        GC 测试主体，--seed 可复现
  cmark             C 基线二进制，交叉编译动态链接

bin/
  test_main         板级 C 测试套件：正确性 / 周期图 / 100 次重复一致性

ko/
  fogccc-irq.ko     IRQ_F2P[0] 内核模块，仅 tests/irq_drv_test.sh 使用

py/
  fogccc.py         Python ctypes 绑定，含 STATUS 与位图探针
  libfogccc.so      Python 绑定用共享库

tests/
  irq_drv_test.sh   中断驱动端到端验证

logs/
  gc_run_*.log      run_gc.sh 输出

----------------------------------------------------------------
不在此分区的内容
  cmark.c           源码位于仓库 csrc/cmark.c
  gic_dump.py / gic_irq_test.py / irq_loss_test.sh
                    位于仓库 tools/，需要时再拷入

常用命令（板上）
  cd /run/media/USERDATA-mmcblk0p2
  也可以挂到 /mnt/userdata:  mkdir -p /mnt/userdata && mount -t vfat /dev/mmcblk0p2 /mnt/userdata
  sh run_gc.sh 4096 8 2
  sh run_cmark.sh 4096 8 2
  sh run_repeat.sh 10
  ./bin/test_main                   需 root
  insmod ko/fogccc-irq.ko
  sh tests/irq_drv_test.sh
