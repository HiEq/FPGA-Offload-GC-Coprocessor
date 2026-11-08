## program_q19.tcl - program the 2^19-queue 1M bitstream over JTAG.
set BIT [file normalize [file join [file dirname [file normalize [info script]]] \
    "fogccc_proj/fogccc_z7100.runs/impl_1/system_wrapper.bit"]]

puts "INFO: bitstream = $BIT"
if {![file exists $BIT]} { puts "ERROR: no bitstream"; exit 1 }

open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target
set dev ""
foreach d [get_hw_devices] {
    set part [get_property PART $d]
    puts "INFO: candidate $d part=$part"
    if {[string match -nocase "*xc7z*" $part]} { set dev $d }
}
if {$dev eq ""} { puts "ERROR: no PL device on the target"; exit 1 }
puts "INFO: device = $dev"
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set_property PROGRAM.FILE $BIT $dev
program_hw_devices $dev
refresh_hw_device -update_hw_probes false $dev
puts "INFO: PROGRAMMED"
close_hw_manager
exit 0
