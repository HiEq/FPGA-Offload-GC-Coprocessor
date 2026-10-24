# ============================================================
# serial_capture_boot.ps1 - wait for the board console and capture a cold boot
#
#   powershell -ExecutionPolicy Bypass -File tools\debug\serial_capture_boot.ps1 `
#       -WaitSeconds 360 -CaptureSeconds 240 -OutFile tools\logs\board_coldboot.raw.log
#
# The board's USB-UART bridge is powered by the board, so with the board off the
# COM port does not exist.  This script polls for the port, opens it as soon as
# Windows enumerates it and then captures continuously, so the Linux boot段 and
# the login prompt land in the log even though U-Boot's first lines may precede
# enumeration.
# ============================================================
param(
    [int]$WaitSeconds = 360,
    [int]$CaptureSeconds = 240,
    [string]$OutFile = 'tools\logs\board_coldboot.raw.log'
)
$ErrorActionPreference = 'Continue'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'serial-session.ps1')

$s = $null
$deadline = (Get-Date).AddSeconds($WaitSeconds)
while (-not $s -and (Get-Date) -lt $deadline) {
    try { $s = New-BoardSerialSession -Port 'auto' } catch { Start-Sleep -Seconds 1 }
}
if (-not $s) { "ERROR: no serial port appeared within $WaitSeconds s"; exit 1 }
"opened {0} @ {1}" -f $s.Port, (Get-Date -Format HH:mm:ss)

$end = (Get-Date).AddSeconds($CaptureSeconds)
while ((Get-Date) -lt $end) {
    try { $c = $s.Sp.ReadExisting(); if ($c) { [void]$s.Sb.Append($c) } } catch {}
    Start-Sleep -Milliseconds 25
}
$all = $s.Sb.ToString()
Close-BoardSerialSession -Session $s

$path = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) $OutFile
[System.IO.File]::WriteAllText($path, $all)
"captured {0} chars -> {1}" -f $all.Length, $path
$plain = ConvertFrom-Ansi $all
foreach ($pat in 'U-Boot', 'Starting kernel', 'Linux version', 'login:', 'root@linux') {
    "  {0,-16}: {1}" -f $pat, $(if ($plain -match [regex]::Escape($pat)) { 'seen' } else { '-' })
}