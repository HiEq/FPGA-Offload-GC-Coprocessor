param([string]$Port = "COM3")

$ErrorActionPreference = 'Stop'
# logs 鐩綍: 鏃ュ織缁熶竴鏀捐繖閲? 涓嶈鍜屽伐鍏锋贩鍦?tools/ 鏍圭洰褰?$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outFile = "$PSScriptRoot\logs\board_verify_$stamp.log"

$sp = New-Object System.IO.Ports.SerialPort $Port,115200,'None',8,'One'
$sp.ReadBufferSize  = 65536
$sp.WriteBufferSize = 65536
$sp.ReadTimeout     = 200
$sp.WriteTimeout    = 3000
$sp.Open()
Write-Host "opened $Port @ 115200"

$sb = New-Object System.Text.StringBuilder

function Pump([int]$ms) {
    $end = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $end) {
        try { $c = $sp.ReadExisting(); if ($c) { [void]$sb.Append($c) } } catch {}
        Start-Sleep -Milliseconds 15
    }
}

function PumpUntil([string]$pattern, [int]$maxMs) {
    $end = (Get-Date).AddMilliseconds($maxMs)
    while ((Get-Date) -lt $end) {
        try { $c = $sp.ReadExisting(); if ($c) { [void]$sb.Append($c) } } catch {}
        if ($sb.ToString() -match $pattern) { return $true }
        Start-Sleep -Milliseconds 15
    }
    return $false
}

function SendLine([string]$s) {
    Write-Host ("> " + $s)
    for ($i = 0; $i -lt $s.Length; $i += 16) {
        $n = [Math]::Min(16, $s.Length - $i)
        $sp.Write($s.Substring($i, $n))
        Start-Sleep -Milliseconds 30
    }
    $sp.Write("`n")
    Start-Sleep -Milliseconds 400
}

function Cmd([string]$s, [int]$waitMs) {
    $before = $sb.Length
    SendLine $s
    [void](PumpUntil '#\s*$' $waitMs)
    Pump 200
}

# --- wake / confirm prompt ---
SendLine ""
[void](PumpUntil '#\s*$' 5000)

Cmd "mkdir -p /mnt/userdata" 8000
Cmd "mount -t vfat /dev/mmcblk0p2 /mnt/userdata" 8000
Cmd "df -h /mnt/userdata | tail -2" 8000
Cmd "ls -l /mnt/userdata/cmark" 8000
Cmd "md5sum /mnt/userdata/cmark" 15000

# --- the actual test ---
Write-Host "`n=== running run_gc.sh (this takes a while) ==="
SendLine "sh /mnt/userdata/run_gc.sh"
$done = PumpUntil 'PASSED \(all invariants\)|FAILED|Traceback' 300000
Write-Host ("  finished=" + $done)
Pump 3000

$sp.Close()
[System.IO.File]::WriteAllText($outFile, $sb.ToString())
Write-Host "`n=== transcript saved: $outFile ==="

$t = $sb.ToString()
Write-Host "=== tail ==="
($t -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 45 | ForEach-Object { "  | " + ($_ -replace "`e",'') }
