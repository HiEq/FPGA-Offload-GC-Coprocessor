param([string]$Port = "COM3")

$ErrorActionPreference = 'Stop'
# logs 鐩綍: 鏃ュ織缁熶竴鏀捐繖閲? 涓嶈鍜屽伐鍏锋贩鍦?tools/ 鏍圭洰褰?$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outFile = "$PSScriptRoot\logs\cmark_sweep_verify_$stamp.log"

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

SendLine ""
[void](PumpUntil '#\s*$' 5000)
Pump 300

# 重启后 /mnt/userdata 需要重新挂载
SendLine "mkdir -p /mnt/userdata"
[void](PumpUntil '#\s*$' 8000)
SendLine "ls /mnt/userdata/cmark >/dev/null 2>&1 || mount -t vfat /dev/mmcblk0p2 /mnt/userdata"
[void](PumpUntil '#\s*$' 10000)
Pump 300

$sets = @(
    @('4096','24','2'),
    @('4096','16','4'),
    @('4096','16','1'),
    @('2048','16','2')
)

$n = 0
foreach ($s in $sets) {
    $n = $n + 1
    $cmd = "sh /mnt/userdata/run_cmark.sh " + $s[0] + " " + $s[1] + " " + $s[2]
    Write-Host ""
    Write-Host ("=== set $n/4 : maxN=" + $s[0] + " trials=" + $s[1] + " avg_refs=" + $s[2] + " ===")
    $mark = "MARK_" + $n + "_" + [DateTime]::Now.Ticks
    SendLine $cmd
    # wait for the final summary line, then wait for a sentinel echo to be sure
    $ok = PumpUntil 'speedup HW vs C-cached' 900000
    Pump 1500
    SendLine ("echo " + $mark)
    [void](PumpUntil $mark 20000)
    Pump 500
    Write-Host ("  done=" + $ok)
}

$sp.Close()
[System.IO.File]::WriteAllText($outFile, $sb.ToString())
Write-Host ""
Write-Host "=== transcript saved: $outFile ==="
