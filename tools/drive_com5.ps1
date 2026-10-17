# ============================================================
# drive_com5.ps1 - drive COM5 directly to run the on-board tests
#                 (no keyboard needed at all)
#
#   Close the fogccc.bat console first (COM5 is exclusive).
#   Usage:  powershell -ExecutionPolicy Bypass -File drive_com5.ps1
#
#   NOTE: all string literals must stay ASCII (see notes F17), otherwise
#         PowerShell 5.1 mis-decodes this UTF-8 file as GBK and fails to parse.
#   NOTE: commands are sent in small chunks.  Dumping a long line in one go
#         gets partly eaten by the login shell's input flush right after login.
# ============================================================
param(
    [string]$Port = "COM3",
    [int]   $Baud = 115200,
    [string]$Out  = "$PSScriptRoot\board_run.log"
)

$sp = New-Object System.IO.Ports.SerialPort $Port,$Baud,'None',8,'One'
$sp.ReadBufferSize  = 65536
$sp.WriteBufferSize = 65536
$sp.ReadTimeout     = 200
$sp.WriteTimeout    = 3000

try { $sp.Open() } catch {
    Write-Host "cannot open $Port : $($_.Exception.Message)"
    Write-Host "most likely the fogccc.bat console is still open - close it first."
    exit 1
}
Write-Host "opened $Port @ $Baud"

$sb = New-Object System.Text.StringBuilder

function Pump([int]$ms) {
    $end = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $end) {
        try { $c = $sp.ReadExisting(); if ($c) { [void]$sb.Append($c); [Console]::Out.Write($c) } } catch {}
        Start-Sleep -Milliseconds 15
    }
}

# pump until the whole transcript matches $pattern (or timeout)
function PumpUntil([string]$pattern, [int]$maxMs) {
    $end = (Get-Date).AddMilliseconds($maxMs)
    while ((Get-Date) -lt $end) {
        try { $c = $sp.ReadExisting(); if ($c) { [void]$sb.Append($c); [Console]::Out.Write($c) } } catch {}
        if ($sb.ToString() -match $pattern) { return $true }
        Start-Sleep -Milliseconds 15
    }
    return $false
}

# send a line in small chunks so the board's line editor never drops it
function SendLine([string]$s) {
    for ($i = 0; $i -lt $s.Length; $i += 16) {
        $n = [Math]::Min(16, $s.Length - $i)
        $sp.Write($s.Substring($i, $n))
        Start-Sleep -Milliseconds 30
    }
    $sp.Write("`n")
    Start-Sleep -Milliseconds 400
}

Write-Host "`n--- 1) wake the prompt ---"
SendLine ""
[void](PumpUntil '#\s*$' 4000)
Pump 500

Write-Host "`n--- 2) login as root ---"
SendLine "root"
[void](PumpUntil '#\s*$' 20000)
Pump 500

Write-Host "`n--- 3) mount USERDATA (two short commands) ---"
SendLine "mkdir -p /mnt/userdata"
[void](PumpUntil '#\s*$' 8000)
SendLine "mount -t vfat /dev/mmcblk0p2 /mnt/userdata"
[void](PumpUntil '#\s*$' 8000)
SendLine "ls /mnt/userdata"
[void](PumpUntil '#\s*$' 8000)

Write-Host "`n--- 4) run run_gc.sh ---"
SendLine "sh /mnt/userdata/run_gc.sh"
if (PumpUntil 'PASSED \(all invariants\)' 150000) { Write-Host "`n[gc_test finished]" }
else { Write-Host "`n[gc_test TIMEOUT]" }
Pump 1500

Write-Host "`n--- 5) run run_cmark.sh ---"
SendLine "sh /mnt/userdata/run_cmark.sh"
if (PumpUntil 'speedup HW vs C' 180000) { Write-Host "`n[cmark finished]" }
else { Write-Host "`n[cmark TIMEOUT]" }
Pump 2000

$sp.Close()
[System.IO.File]::WriteAllText($Out, $sb.ToString())
Write-Host "`n=== full transcript saved to: $Out ==="
