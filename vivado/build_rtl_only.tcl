# ============================================================
# build_rtl_only.tcl — 只改 RTL 时的快速重编 (不重建 Block Design)
#
# 什么时候能用:
#   gc_top 的**端口没变**、BD 没变, 只改了 rtl/*.v 的内部逻辑.
#   (本次的改动: gc_mark_engine 里加了一个内部寄存器 prev_ref — 端口没变 ✓)
#
# 比 build.tcl 快在哪:
#   跳过 create_project + BD 生成 + IP 生成 (那部分要好几分钟),
#   直接复用现有工程, 只重跑 综合 -> 实现 -> 比特流 -> XSA.
#
# 用法:
#   cd C:\Users\wwwmt\Desktop\FOGCCC2\vivado
#   D:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat -mode batch -source build_rtl_only.tcl -log vivado_build.log -journal vivado_build.jou
#
# 注意: 如果改了 gc_top 的端口 / 加了新模块 / 动了 BD, 请改用 build.tcl
# ============================================================
set SCRIPT_DIR [file dirname [file normalize [info script]]]
set PROJ_DIR   [file normalize [file join $SCRIPT_DIR "fogccc_proj"]]
set RTL_DIR    [file normalize [file join $SCRIPT_DIR ".." "rtl"]]
set XPR        [file normalize [file join $PROJ_DIR "fogccc_z7100.xpr"]]

# 综合/实现并行线程数 —— 必须最先设置
set_param general.maxThreads 20

if {![file exists $XPR]} {
    puts "ERROR: 找不到工程 $XPR"
    puts "       第一次请先跑 build.tcl (需要生成 BD)"
    exit 1
}

puts "INFO: 打开现有工程 (复用 BD 与 IP)"
open_project $XPR

puts "INFO: RTL 源目录 = $RTL_DIR"
update_compile_order -fileset sources_1

puts "INFO: 重新综合 (线程 20)"
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: 综合失败"
    exit 1
}
puts "INFO: Synthesis PASSED"

puts "INFO: 重新实现"
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: 实现失败"
    exit 1
}
puts "INFO: Implementation PASSED"

open_run impl_1
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
if {$wns < 0} { puts "WARNING: 时序违例! WNS = $wns ns" } else { puts "INFO: Timing MET! WNS = $wns ns" }

report_utilization    -file [file join [file normalize $PROJ_DIR] utilization.rpt]
report_timing_summary -file [file join [file normalize $PROJ_DIR] timing.rpt]

puts "INFO: 导出 XSA"
write_hw_platform -fixed -include_bit -force [file join [file normalize $PROJ_DIR] "system.xsa"]

puts ""
puts "============================================"
puts "  FAST BUILD COMPLETE (RTL only)"
puts "============================================"
puts "  Bitstream : [file join $PROJ_DIR fogccc_z7100.runs impl_1 system_wrapper.bit]"
puts "  Hardware  : [file join $PROJ_DIR system.xsa]"
puts "============================================"
