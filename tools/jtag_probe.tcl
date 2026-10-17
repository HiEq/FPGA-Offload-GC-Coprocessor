connect
puts "== xsct targets =="
if {[catch {puts [targets]} e]} { puts "targets error: $e" }
if {[catch {jtag autodetect} e]} { puts "autodetect: $e" }
if {[catch {puts [jtag targets]} e]} { puts "jtag targets error: $e" }
exit
