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
    SendLine $s
    [void](PumpUntil '#\s*$' $waitMs)
    Pump 200
}

# ================= 1) login =================
Write-Host "--- 1) login ---"
Pump 500
$sp.Write("`r")
Pump 1200

$loggedIn = $false
for ($try = 1; $try -le 3; $try++) {
    if ($sb.ToString() -match '#\s*$') { $loggedIn = $true; break }
    Write-Host ("  attempt " + $try + ": sending user root")
    $sp.Write("root`n")
    Pump 2500
    if ($sb.ToString() -match 'Password:') {
        Write-Host "  password prompt -> sending empty password"
        $sp.Write("`n")
        Pump 2500
    }
    if (PumpUntil '#\s*$' 15000) { $loggedIn = $true; break }
}
Write-Host ("  logged in = " + $loggedIn)
if (-not $loggedIn) {
    Write-Host "  LOGIN FAILED, tail:"
    $t = $sb.ToString()
    ($t -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 15 | ForEach-Object { "  | " + $_ }
    $sp.Close()
    [System.IO.File]::WriteAllText($outFile, $sb.ToString())
    exit 2
}
Pump 400

# ================= 2) mount + check =================
Write-Host "--- 2) mount + verify files ---"
Cmd "mkdir -p /mnt/userdata" 8000
Cmd "mount -t vfat /dev/mmcblk0p2 /mnt/userdata" 8000
Cmd "df -h /mnt/userdata | tail -2" 8000
Cmd "md5sum /mnt/userdata/cmark" 15000
Cmd "ls -l /mnt/boot/BOOT.BIN 2>/dev/null || ls -l /run/media/*/BOOT.BIN 2>/dev/null || echo no-boot-mount" 10000
Cmd "cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || echo no-fpga-manager" 8000

# ================= 3) run_gc.sh =================
Write-Host "--- 3) run_gc.sh ---"
SendLine "sh /mnt/userdata/run_gc.sh"
$done = PumpUntil 'PASSED \(all invariants\)|FAILED|Traceback' 420000
Write-Host ("  finished = " + $done)
Pump 3000

$sp.Close()
[System.IO.File]::WriteAllText($outFile, $sb.ToString())
Write-Host ("transcript: " + $outFile)

$t = $sb.ToString()
Write-Host "--- tail ---"
($t -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 30 | ForEach-Object { "  | " + ($_ -replace "`e",'') }
