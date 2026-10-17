# ============================================================
# hw_program.tcl - program the PL over JTAG (no reboot, no card swap)
#
#   usage:
#     vivado -mode batch -source tools/hw_program.tcl -tclargs <bitfile>
#
#   Note: the design must be idle.  Reconfiguring the PL resets the
#   AXI-Lite registers; the on-board test re-writes them on every run.
# ============================================================
set bitfile [lindex $argv 0]
if {$bitfile eq ""} {
    puts "ERROR: no bitfile given"
    exit 1
}
if {![file exists $bitfile]} {
    puts "ERROR: bitfile not found: $bitfile"
    exit 1
}
puts "INFO: programming $bitfile"

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices xc7z100_1] 0]
if {$dev eq ""} {
    puts "ERROR: xc7z100_1 not found"
    exit 1
}
current_hw_device $dev
set_property PROGRAM.FILE $bitfile $dev
program_hw_devices $dev
refresh_hw_device $dev
if {[catch {set prog [get_property PROGRAM.IS_PROGRAMMED $dev]} e]} { set prog "(n/a)" }
puts "PROGRAMMED_OK  $bitfile  is_programmed=$prog"
close_hw_target
disconnect_hw_server
close_hw_manager
exit
