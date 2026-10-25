# ============================================================
# cold_cycle.ps1 - reboot the board, wait for the login prompt with reads only,
#   then run one command as the FIRST thing after the fresh PL configuration.
#
#   powershell -File tools\debug\cold_cycle.ps1 -Name regs_aww_acked `
#       -Cmd "cd /run/media/USERDATA-mmcblk0p2 && python3 -u tests/regs_aww_board_test.py --acked"
# ============================================================
param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$Cmd,
    [string]$Until = 'DIAG_DONE',
    [int]$MaxMs = 600000,
    [string]$BootLog = '',
    [string]$Bitstream = '3332D8D631A8DB5D8091972DFEE5565E',
    [string]$BootSha = 'ac8d31cc79ae40b21c83d01e3d943b1205bd825f24c51a3e5bb49ac439e8c4d4'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$runner = Join-Path $root 'tools\debug\board_cmd.ps1'
$logs = Join-Path $root 'tools\logs'

Write-Host '=== reboot ==='
& powershell -NoProfile -ExecutionPolicy Bypass -File $runner `
    -Cmd "sync; reboot" -Until 'Restarting system' -MaxMs 60000 | Out-Null
Start-Sleep -Seconds 5

Write-Host '=== wait for login (read-only) ==='
$waitArgs = @{ MaxMs = 240000 }
if ($BootLog -ne '') { $waitArgs.OutFile = $BootLog }
$state = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'wait_boot.ps1') @waitArgs
$state | ForEach-Object { '  ' + $_ }

Write-Host ("=== {0} (first run after boot) ===" -f $Name)
$log = Join-Path $logs ("board_{0}.log" -f $Name)
$out = & powershell -NoProfile -ExecutionPolicy Bypass -File $runner `
    -Cmd ($Cmd + "; printf 'D''IAG_DONE\n'") -Until 'DIAG_DONE' -MaxMs $MaxMs -OutFile $log 2>&1 |
    ForEach-Object { $_.ToString() }

$sha = (& git -C $root rev-parse --short HEAD).Trim()
$hdr = @(
    "# command: tools/debug/cold_cycle.ps1 -> $Name (first run after a reboot)",
    "# bitstream: $Bitstream   boot.bin: sha256 $BootSha",
    "# commit: $sha   VERSION=0x00040301",
    ('# date: {0}' -f (Get-Date -Format 'yyyy-MM-dd')),
    ''
)
if (Test-Path $log) {
    $body = [IO.File]::ReadAllText($log)
    [IO.File]::WriteAllText($log, (($hdr -join "`n") + $body), (New-Object Text.UTF8Encoding $false))
}
$out | Where-Object { $_ -match 'RESULT|loss=|retries|giveup|VERDICT|round|marked|occ=|PASS|FAIL' } |
    Select-Object -Last 12 | ForEach-Object { '  ' + $_.Trim().Substring(0, [Math]::Min(150, $_.Trim().Length)) }
