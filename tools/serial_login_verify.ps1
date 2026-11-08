param([string]$Port = 'COM9', [int]$Baud = 921600)
$ErrorActionPreference = 'Continue'
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.ReadTimeout = 200
$sp.Open()
$rx = New-Object System.Text.StringBuilder
function Drain { try { $c = $sp.ReadExisting(); if ($c) { [void]$rx.Append($c) } } catch {} }
function Send([string]$s) { $sp.Write($s) }
function WaitPat([string]$pat, [int]$ms) {
    $end = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $end) {
        Start-Sleep -Milliseconds 100; Drain
        if ($rx.ToString() -match $pat) { return $true }
    }
    return $false
}
Send "`r"; Start-Sleep -Milliseconds 700; Drain
if ($rx.ToString() -match 'login:') {
    Send "root`r"; Start-Sleep -Milliseconds 1500
    Send "`r"; Start-Sleep -Milliseconds 1200
}
$rx.Clear() | Out-Null
Send "byobu kill-server`r"; Start-Sleep -Seconds 2; Send "`r"; Start-Sleep -Seconds 1; Drain
if ($rx.ToString() -match 'login:') {
    Send "root`r"; Start-Sleep -Milliseconds 1500
    Send "`r"; Start-Sleep -Milliseconds 1200
}
$rx.Clear() | Out-Null
Send "id; uname -a; grep -E 'BogoMIPS|Processor' /proc/cpuinfo | head -4; echo FPGA:; cat /sys/class/fpga_manager/fpga0/state 2>/dev/null; echo VER:; devmem 0x43C00034 32 2>/dev/null; echo CARD:; ls /run/media/USERDATA-mmcblk0p2 2>/dev/null | head; echo DONE_OK`r"
[void](WaitPat 'DONE_OK' 12000)
Drain
Start-Sleep -Milliseconds 500
$sp.Close()
$rx.ToString()
