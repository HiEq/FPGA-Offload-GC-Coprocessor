param(
    [string]$Port = 'auto',
    [int]$MaxMs = 180000,
    [string]$OutFile = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'serial-session.ps1')
$s = New-BoardSerialSession -Port $Port
# Read-only: never write during the boot window.
[void](Read-BoardSerialUntil -Session $s -Pattern 'login:|root@|Zynq>' -MaxMs $MaxMs)
$txt = ConvertFrom-Ansi $s.Sb.ToString()
if ($OutFile -ne '') { [System.IO.File]::WriteAllText($OutFile, $txt) }
$state = if ($txt -match 'root@') { 'shell' } elseif ($txt -match 'login:') { 'login' } elseif ($txt -match 'Zynq>') { 'uboot' } else { 'unknown' }
"state: $state  (chars=$($txt.Length))"
($txt -split "`r?`n" | Where-Object { $_ -ne '' } | Select-Object -Last 10) | ForEach-Object { '  |' + $_.Trim() }
Close-BoardSerialSession -Session $s
