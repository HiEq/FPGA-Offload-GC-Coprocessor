connect
after 2000
targets
target -set -filter {name =~ "ARM Cortex-A9 MPCore #0"}
after 500

catch {stop} r
puts "=== PC ==="
puts [rr pc]

puts "=== DDR ==="
catch {mwr 0x00100000 0xDEADBEEF} r
catch {mrd 0x00100000} r
puts $r

puts "=== U-Boot ==="
catch {mrd 0x04000000 1} r
puts "U-Boot: $r"

puts "=== DT at _end (0x04106C30) ==="
catch {mrd 0x04106C30 1} r
puts "DT: $r"

puts "=== UART CSR ==="
catch {mrd 0xE000002C} r
puts $r

puts "=== PC x5 ==="
for {set i 0} {$i < 5} {incr i} {
    puts [rr pc]
    after 500
}
