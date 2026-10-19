param([string]$Port = "auto")

$ErrorActionPreference = 'Stop'

# Port auto-detection: the CH340 re-enumerates across reboots (COM3 -> COM5 ...).
# Pass -Port COMx to override.
. (Join-Path $PSScriptRoot 'serial-port.ps1')
$Port = Resolve-SerialPort $Port
# logs directory
$logDir = Join-Path $PSScriptRoot 'logs'
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

# $from makes a caller ignore everything already in $sb. The buffer keeps the whole
# session (login banner, earlier commands), so a stale line there would satisfy the
# pattern before the new command has produced a single byte.
function PumpUntil([string]$pattern, [int]$maxMs, [int]$from = 0) {
    $end = (Get-Date).AddMilliseconds($maxMs)
    while ((Get-Date) -lt $end) {
        try { $c = $sp.ReadExisting(); if ($c) { [void]$sb.Append($c) } } catch {}
        if ($sb.Length -gt $from -and $sb.ToString($from, $sb.Length - $from) -match $pattern) { return $true }
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
    $from = $sb.Length
    SendLine $s
    if (-not (PumpUntil '#\s*$' $waitMs $from)) {
        Write-Host ("  (no prompt within {0} ms after: {1})" -f $waitMs, $s)
    }
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

# ================= 1b) 宿主时间同步 =================
# 板上没有 RTC 也没有网络, 每次上电时钟都退回 2018-03-09. 这里把宿主的 UTC 时间灌进去,
# 这样 run_gc.sh 写出的 gc_run_*.log 文件名才是真实日期.
Write-Host "--- 1b) host time sync ---"
$hostUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
Cmd "date -s '$hostUtc'" 8000
Cmd "date" 8000

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
# Only output produced from here on may satisfy the verdict pattern: $sb still holds
# the whole session, and an old 'FAILED' line in it used to report finished=True a
# couple of seconds after the run started.
$from = $sb.Length
SendLine "sh /mnt/userdata/run_gc.sh"
$done = PumpUntil 'PASSED \(all invariants\)|FAILED|Traceback' 420000 $from
Write-Host ("  finished = " + $done)
if ($done) {
    $new = $sb.ToString($from, $sb.Length - $from)
    $ml  = ($new -split "`r?`n") | Where-Object { $_ -match 'PASSED \(all invariants\)|FAILED|Traceback' } | Select-Object -First 1
    Write-Host ("  verdict line: " + (($ml -replace '\x1b\[[0-9;?]*[a-zA-Z]','' -replace '\x1b','').Trim()))
}
Pump 3000

$sp.Close()
[System.IO.File]::WriteAllText($outFile, $sb.ToString())
Write-Host ("transcript: " + $outFile)

$t = $sb.ToString()
Write-Host "--- tail ---"
($t -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 30 | ForEach-Object { "  | " + ($_ -replace '\x1b\[[0-9;?]*[a-zA-Z]','' -replace '\x1b','') }
