open_hw_manager
connect_hw_server -allow_non_jtag
puts "== hw_server connected =="
open_hw_target
puts "== target opened =="
set devs [get_hw_devices]
if {[llength $devs] == 0} {
    puts "NO DEVICES FOUND"
} else {
    foreach d $devs {
        if {[catch {set part [get_property PART $d]} e]} { set part "(n/a)" }
        if {[catch {set prog [get_property PROGRAM.IS_PROGRAMMED $d]} e]} { set prog "(n/a)" }
        puts "  DEVICE: $d   PART=$part   PROGRAMMED=$prog"
    }
}
close_hw_target
disconnect_hw_server
close_hw_manager
exit
