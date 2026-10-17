param([string]$Port = "COM3")

$ErrorActionPreference = 'Stop'
# logs 鐩綍: 鏃ュ織缁熶竴鏀捐繖閲? 涓嶈鍜屽伐鍏锋贩鍦?tools/ 鏍圭洰褰?$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$sp = New-Object System.IO.Ports.SerialPort $Port,115200,'None',8,'One'
$sp.ReadBufferSize = 65536
$sp.ReadTimeout = 200
$sp.Open()
$sb = New-Object System.Text.StringBuilder

function Pump([int]$ms) {
    $end = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $end) {
        try { $c = $sp.ReadExisting(); if ($c) { [void]$sb.Append($c) } } catch {}
        Start-Sleep -Milliseconds 30
    }
}

function PumpUntil([string]$pattern, [int]$maxMs) {
    $end = (Get-Date).AddMilliseconds($maxMs)
    while ((Get-Date) -lt $end) {
        try { $c = $sp.ReadExisting(); if ($c) { [void]$sb.Append($c) } } catch {}
        if ($sb.ToString() -match $pattern) { return $true }
        Start-Sleep -Milliseconds 30
    }
    return $false
}

Write-Host "--- waiting for login prompt (passive) ---"
$ok = PumpUntil 'linux login:' 240000
Write-Host ("  login prompt: " + $ok)
if (-not $ok) {
    Write-Host "  NOT reached, tail:"
    $t = $sb.ToString()
    ($t -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 25 | ForEach-Object { "  | " + $_ }
    $sp.Close()
    exit 2
}

Write-Host "--- sending user 'root' ---"
$sp.Write("root`n")
Pump 2500

if ($sb.ToString() -notmatch '#\s*$') {
    if ($sb.ToString() -match 'Password:') {
        Write-Host "--- password prompt seen, sending empty password ---"
        $sp.Write("`n")
        Pump 2500
    }
}

$gotShell = PumpUntil '#\s*$' 20000
Write-Host ("  shell prompt: " + $gotShell)
Pump 300
$sp.Close()

[System.IO.File]::WriteAllText("$PSScriptRoot\logs\boot_login.log", $sb.ToString())
$t = $sb.ToString()
Write-Host "--- transcript tail ---"
($t -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 30 | ForEach-Object { "  | " + $_ }
