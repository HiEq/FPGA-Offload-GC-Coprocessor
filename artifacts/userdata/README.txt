FOGCCC USERDATA 分区说明
================================================================

根目录：入口脚本及其直接依赖（脚本用 dirname 定位同级文件）
  fpga_vs_python.sh         主测试入口，需同级 fpga_vs_python.py
  fpga_vs_python_repeat.sh     重复测量，调用以上两个
  fpga_vs_python.py        GC 测试主体，--seed 可复现

bin/
  test_main         板级 C 测试套件：正确性 / 周期图 / 100 次重复 / 重复根

ko/
  fogccc-irq.ko     IRQ_F2P[0] 内核模块，仅 tests/irq_drv_test.sh 使用

py/
  fogccc.py         Python ctypes 绑定，含 STATUS 与位图探针
  libfogccc.so      Python 绑定用共享库

tests/
  irq_drv_test.sh   中断驱动端到端验证
  abort_test.py     CTRL[3] abort 五段验收
  abort_sweep.py    abort 相位扫描（--delays 可重复单点）
  done_race_test.py stale-DONE 实验 + 连续换图回归
  freelist_contract_test.py / freelist_n4096_test.py
                    free-list 契约负控 / 4096 边界全覆盖
  dirty_set_test.py / dirty_concurrent_test.py / dirty_overflow_test.py / dirty_leftover_test.py / dirty_state.py
                    阶段 3A/3B 脏集、并发增量、溢出、残留、收尾查脏 FIFO
  ctrl_spill_test.py CTRL 写重投递的溢出防护验证
  dirty_api_test.py  阶段 3A C 驱动 + ctypes 绑定验收（含 --neg）
  py_bfs.py         Python BFS oracle（fpga_vs_python.sh 用）

logs/
  gc_run_*.log      fpga_vs_python.sh 输出

----------------------------------------------------------------
不在此分区的内容
  gic_dump.py / gic_irq_test.py / irq_loss_test.sh
                    位于仓库 tools/debug/，需要时再拷入

常用命令（板上）
  cd /run/media/USERDATA-mmcblk0p2
  也可以挂到 /mnt/userdata:  mkdir -p /mnt/userdata && mount -t vfat /dev/mmcblk0p2 /mnt/userdata
  sh fpga_vs_python.sh 4096 8 2
  sh fpga_vs_python_repeat.sh 10
  ./bin/test_main                   需 root
  insmod ko/fogccc-irq.ko
  sh tests/irq_drv_test.sh
