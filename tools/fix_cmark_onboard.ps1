# ============================================================
# fix_cmark_onboard.ps1 - rebuild cmark ON the board (dynamic, no -static)
#                         and immediately run run_cmark.sh
#
#   Why dynamic: the board's rootfs has no static libc (ld: cannot find -lc),
#   so the gcc build must link against the shared libc.
#
#   Close the fogccc.bat console first (COM5 is exclusive).
#   Usage: powershell -ExecutionPolicy Bypass -File fix_cmark_onboard.ps1
#   ASCII-only strings on purpose (notes F17).
# ============================================================
param([string]$Port = "COM3", [int]$Baud = 115200)

$sp = New-Object System.IO.Ports.SerialPort $Port,$Baud,'None',8,'One'
$sp.ReadBufferSize  = 131072
$sp.WriteBufferSize = 131072
$sp.ReadTimeout     = 200
$sp.WriteTimeout    = 5000

try { $sp.Open() } catch {
    Write-Host "cannot open $Port : $($_.Exception.Message)"
    Write-Host "close the fogccc.bat console first."
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
function PumpUntil([string]$pattern, [int]$maxMs) {
    $end = (Get-Date).AddMilliseconds($maxMs)
    while ((Get-Date) -lt $end) {
        try { $c = $sp.ReadExisting(); if ($c) { [void]$sb.Append($c); [Console]::Out.Write($c) } } catch {}
        if ($sb.ToString() -match $pattern) { return $true }
        Start-Sleep -Milliseconds 15
    }
    return $false
}
function SendLine([string]$s, [int]$chunk = 24, [int]$gap = 20) {
    for ($i = 0; $i -lt $s.Length; $i += $chunk) {
        $n = [Math]::Min($chunk, $s.Length - $i)
        $sp.Write($s.Substring($i, $n)); Start-Sleep -Milliseconds $gap
    }
    $sp.Write("`n"); Start-Sleep -Milliseconds 200
}

Write-Host "`n--- sync ---"
SendLine ""; Pump 800

Write-Host "`n--- mount ---"
SendLine "mkdir -p /mnt/userdata"; Pump 500
SendLine "mount -t vfat /dev/mmcblk0p2 /mnt/userdata 2>/dev/null"; Pump 800

Write-Host "`n--- size + rebuild (DYNAMIC: no -static) ---"
SendLine "wc -c /mnt/userdata/cmark.c"; Pump 800
SendLine "rm -f /mnt/userdata/cmark"
SendLine "gcc -O2 -o /mnt/userdata/cmark /mnt/userdata/cmark.c && echo COMPILE_OK"
Pump 12000
SendLine "ls -l /mnt/userdata/cmark"; Pump 1200

Write-Host "`n--- run run_cmark.sh ---"
SendLine "sh /mnt/userdata/run_cmark.sh"
if (PumpUntil 'speedup HW vs C' 180000) { Write-Host "`n[cmark finished]" } else { Write-Host "`n[cmark TIMEOUT]" }
Pump 2000

$sp.Close()
$out = "$PSScriptRoot\logs\cmark_onboard.log"
[System.IO.File]::WriteAllText($out, $sb.ToString())
Write-Host "`n=== transcript: $out ==="
