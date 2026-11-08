# Close the last 0.1 ns of the 150 MHz build (post-route physical optimisation).
set SCRIPT_DIR [file dirname [file normalize [info script]]]
set PROJ_DIR   [file normalize [file join $SCRIPT_DIR "fogccc_proj"]]
open_project [file join $PROJ_DIR "fogccc_z7100.xpr"]
open_run impl_1
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
report_timing_summary -file [file join $SCRIPT_DIR "timing_150_final.rpt"]
write_bitstream -force [file join $PROJ_DIR "fogccc_z7100.runs" "impl_1" "system_wrapper.bit"]
close_project
