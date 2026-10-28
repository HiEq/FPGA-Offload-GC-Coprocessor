# tools/tests/ —— 功能测试

性能基准入口为 ../serial_fpga_vs_python.ps1。本目录只放功能性验证脚本。
运行条件：板子在运行，串口空闲。日志写入 tools/logs/。调试工具见 ../debug/。

| 脚本 | 类型 | 用途 |
|---|---|---|
| fpga_vs_python.py | 功能 + 性能（板级） | 卡上 fpga_vs_python.sh 调用的同一份；--seed N 可复现；mark 后校验 FREE_COUNT/FREE_DATA |
| side_table_test.py | 功能（板级） | Phase 1/2：用 gc.get_referents（tp_traverse）构建真实 解释器容器图；mark 后按 FREE_COUNT/FREE_DATA 校验 free 集合；--neg 注入故障 |
| irq_drv_test.sh | 功能（验收级） | 中断端到端：done → GIC SPI 61 → 内核 handler |
| fpga_vs_c_vs_python.py | 性能（板级） | 同一张图依次运行 FPGA / C 未缓存 / C 缓存 / Python，四个计数必须相等；C 计时在 C 内完成 |
| abort_test.py | 功能（板级） | CTRL[3] abort：T1 基线 / T2 控制组（不写 abort 必须执行完毕）/ T3 abort 后 DONE 必须始终为 0 / T4 同一张图恢复 / T5 **换一张不同规模的图**（危险路径：上一轮残留会被多标） |
| abort_sweep.py | 功能（板级） | abort **相位扫描**：0–480 µs 逐点打断（位图清零 / 根处理 / 头部读 / 引用读 / 收尾），每个相位都必须停住并精确恢复；--delays 3,3,3 可重复同一相位 |
| done_race_test.py | 功能（板级） | START 是 posted write 的 stale-DONE 竞态（AGENTS gap 9）+ 连续换图（P3 用驱动同样的"读回 + usleep(1) + 轮询"顺序，每轮必须返回本轮自己的 L） |
| freelist_contract_test.py | 契约（板级） | Phase 2 free-list 软件契约负控：**A** 扫描期间读位图探针 = 扫描器自己的字（free 结果仍精确）/ **B** DONE 后不等 STATUS[5] 就读 FREE_COUNT = 残值（天真正软件会漏 free）/ **C** 文档流程精确 / **D** 扫描中写 START 重新执行后结果精确、STATUS=0x10 |
| dirty_set_test.py | 功能（板级） | Phase 3A 脏集：**A0** 无屏障不标记（负控）/ **A** 无根+脏{0,40,41} → marked=6、free=58（精确），pushed==occ 且 ∈[3,6)、三计数自洽（本板写路径会重复投递，计数有界，见 README）/ **B** BM_KEEP + 已标容器强制重扫 / **C** 256 深溢出标志 + flush 清除 / **D** 真容器图两 epoch（标记集 == CPU oracle 精确、drained==pushed ∈[dirty,2·dirty)、free=未标记）/ **D-neg** 无屏障 → 新目标必须漏标 |
| dirty_concurrent_test.py | 功能（板级） | Phase 3B 并发+remark：热容器种子（引用表 1024）撑住增量 epoch ≈5.4 ms；mutator 线程在 CTRL[DONE]==0 时推送并自增 live_pushes（37~41/100，非采样）；每轮校验 marked==oracle、free=未标记、pushed==popped==drained、pushed ≥ 种子+预算、无溢出/无 STATUS 错误位；5 轮压力 + no-barrier 负控（missed=142）|
| ctrl_spill_test.py | 功能（板级） | 迟到的 CTRL 写不得污染运行中的 epoch：运行中写 CTRL=CLEAR_Q 与 CTRL=START（模拟本板"非相邻重投递"），断言 q_tail == marked == 200。未防护位流在仿真里是 198/398 ⇒ 该测试同时是"卡上位流确实含防护"的**功能性证据**（VERSION 两版相同，分不出来）|
| freelist_n4096_test.py | 功能（板级） | 4096 边界的全空闲：root_count=0 ⇒ 引擎不标记任何对象，扫描器必须报 free_count=4096、无重复、无越界、缺项为空（判定已退役的 tb_freelist 273 errors 是台架陈旧，非 RTL 缺口）|
| dirty_api_test.py | 功能（板级） | 通过 **C 驱动 + ctypes 绑定**（fogccc.py/libfogccc.so）驱动阶段 3A：全标记 → 增量 epoch（roots=0、不 flush）标记数恰为 closure(live,pushed)-live、pushed==popped==drained → 256 深 FIFO 压满（pushed==256/ovf=1）→ dirty_flush() 清零。--neg（固定 tag 直写 0x440）必须被抓成 FAIL |
| dirty_overflow_test.py | 功能（板级） | Phase 3A 溢出契约：并发中把 256 深 FIFO 压满（热容器种子撑住引擎 + 主线程一条推送洪流），断言 occ=256/ovf=1/并发被采样到；**负控**：忽略溢出标志继续增量 ⇒ marked != oracle（漏标，证明退回全标记是必须的）；**契约**：bm_keep=0 + CTRL[5] 全标记 ⇒ marked==oracle、free=未标记、STATUS=0、flush 清掉粘滞位 |
| dirty_leftover_test.py | 功能（板级） | 全标记必须与 CTRL[5] 脏集 flush 同发：先留 2 条屏障记录再执行 ./bin/test_main —— 旧二进制 ⇒ q_tail=10 != marked=9 失败，修好的二进制 ⇒ ALL PASS（负控与验证一体的定向用例，见 AGENTS #18）|
| dirty_state.py | 探针（板级） | 打印脏 FIFO 状态（occ/ovf/tag/drained/pushed/popped + VERSION），--flush 只**预置**（arm；下一次全标记 START 才生效）；run_phase3_board.ps1 收尾用它核查 occ=0 |
| regs_aww_board_test.py | 功能（板级） | AGENTS #20 的 B2：15 轮"清场 → 推 K 条（每个对象 ref_count=0，故标记集应恰为推力集）→ 全标记 epoch"，逐轮报 loss/多余标记。断言**只针对丢记录**（漏重扫不安全，多标安全）；第 0 轮作"重启后第一次 DPUSH"窗口，只报告不断言。用法：重启后立即执行 |

## 用法

```sh
cd /run/media/USERDATA-mmcblk0p2 && python3 tests/fpga_vs_c_vs_python.py
```

板上运行：脚本自带的默认 D 就是 /run/media/USERDATA-mmcblk0p2，从该目录执行正好命中——`sh tests/irq_drv_test.sh`；
如果数据分区挂在 /mnt/userdata，要显式传：D=/mnt/userdata sh tests/irq_drv_test.sh。

**启动窗口内只读不写**：U-Boot 的 bootdelay 里收到任何字节都会中止 autoboot、掉进 Zynq>（现象：后面发的命令变成
Unknown command '...'）。所以探活只读（Read-BoardSerial*），看到 root@/login: 再写；看到 Zynq> 就发 boot
恢复。`tools/debug/diag_run.ps1` 已按这条规则实现。
>
负控（2026-10-24 实测）：故意在启动窗口里灌 48 个 CR → 板子确实停在 Zynq>；随后 diag_run.ps1 无人干预
自愈（boot → 登录 → 执行），输出 DIAG_OK、rc=0。

卡上 USERDATA/tests/ 里的同名文件由 `make card` 从本目录**生成**；不要手改卡上那份（会被覆盖）。

dirty_set_test.py / dirty_overflow_test.py / dirty_concurrent_test.py 自己在开头写 0x04 R_OBJ_BASE
（该寄存器**复位值是 0**，不能依赖上一个测试留下的残值）；依赖残值的版本在重启后会"只标记、不追引用"，
负控见 tools/logs/board_phase3_dirty_set_base_neg_20261023.log 与 AGENTS #19。
>
**执行顺序敏感**：DIRTY_PUSH 突发如果发生在 PL 刚配置后的第一批写里，可能被本板的重投递打乱
（AW/W 乱配 ⇒ 伪造或丢失一条记录）。因此 dirty_set_test.py 在“重启后第一个执行”时会失败，而
run_phase3_board.ps1（先执行 test_main）不受影响；复现件见
tools/logs/board_phase3_dirty_set_boot_neg_20261023.log，分析见 AGENTS #20（**开放**）。

### CI 的 RTL 覆盖边界

.github/workflows/lint.yml 用 **Icarus** 执行 tb_runstart_race、tb_cmdfifo_flush、tb_gc_top
和三个 hand-over TB，其余同行是语法/清单检查。**free-list 与 dirty-set 的用例都在 sim/tb_gc_top.v 里，需要 Vivado xsim**
（sim/run_sim.sh|bat），证据是 tools/logs/host_reproduce.log 而不是 CI。补这个缺口需要给 dirty FIFO
写一个 Icarus 可执行的单元 tb（本机没装 iverilog，尚未验证）。
