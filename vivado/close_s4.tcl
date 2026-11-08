set SCRIPT_DIR [file dirname [file normalize [info script]]]
set PROJ_DIR   [file normalize [file join $SCRIPT_DIR "fogccc_proj"]]
set XPR        [file normalize [file join $PROJ_DIR "fogccc_z7100.xpr"]]
set BIT        [file normalize [file join $PROJ_DIR "fogccc_z7100.runs" "impl_1" "system_wrapper.bit"]]

set_param general.maxThreads 20
open_project $XPR
open_run impl_1

puts "INFO: phys_opt_design AggressiveExplore on the routed design"
phys_opt_design -directive AggressiveExplore

puts "INFO: re-routing"
route_design

puts "INFO: timing"
report_timing_summary -file [file join $PROJ_DIR timing.rpt]
report_utilization    -file [file join $PROJ_DIR utilization.rpt]
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
if {$wns < 0} { puts "WARNING: TIMING VIOLATION WNS = $wns ns" } else { puts "INFO: Timing MET WNS = $wns ns" }

puts "INFO: bitstream"
write_bitstream -force $BIT

puts "INFO: XSA"
write_hw_platform -fixed -include_bit -force [file join $PROJ_DIR "system.xsa"]

puts "INFO: CLOSE_S4 DONE WNS=$wns"
