# ============================================================
# run_board_suite.ps1 - the warm-image board regression (everything that is
#   NOT covered by run_phase3_board.ps1 and the three_way comparison).
#
#   Each step goes through tools\debug\board_cmd.ps1, which probes with reads
#   only until a shell prompt is seen and never writes during the boot window.
#   Per-step output lands in tools\logs\<log>.log with a provenance header.
#
#   powershell -File tools\debug\run_board_suite.ps1 [-Only abort,done_race]
# ============================================================
param(
    [string]$DataDir = '/run/media/USERDATA-mmcblk0p2',
    [string]$Only = '',
    [string]$Bitstream = '3332D8D631A8DB5D8091972DFEE5565E',
    [string]$BootSha = 'ac8d31cc79ae40b21c83d01e3d943b1205bd825f24c51a3e5bb49ac439e8c4d4'
)
$ErrorActionPreference = 'Continue'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$runner = Join-Path $root 'tools\debug\board_cmd.ps1'
$logs = Join-Path $root 'tools\logs'
$sha = (& git -C $root rev-parse --short HEAD).Trim()

$steps = @(
    @('dirty_api',        "cd $DataDir && python3 -u tests/dirty_api_test.py"),
    @('freelist_n4096',   "cd $DataDir && python3 -u tests/freelist_n4096_test.py"),
    @('abort_test',       "cd $DataDir && python3 -u tests/abort_test.py"),
    @('abort_sweep',      "cd $DataDir && python3 -u tests/abort_sweep.py"),
    @('done_race',        "cd $DataDir && python3 -u tests/done_race_test.py"),
    @('run_gc',           "cd $DataDir && sh fpga_vs_python.sh 4096 8 2"),
    @('repeat',           "cd $DataDir && sh fpga_vs_python_repeat.sh 10"),
    @('irq',              "cd $DataDir && sh tests/irq_drv_test.sh"),
    @('regs_aww_acked',   "cd $DataDir && python3 -u tests/regs_aww_board_test.py --acked"),
    @('dirty_concurrent_plain', "cd $DataDir && python3 -u tests/dirty_concurrent_test.py --plain-push")
)

$want = @()
if ($Only -ne '') { $want = $Only -split ',' | ForEach-Object { $_.Trim() } }

foreach ($st in $steps) {
    $name, $cmd = $st[0], $st[1]
    if ($want.Count -gt 0 -and $want -notcontains $name) { continue }
    Write-Host ("=== {0} ===" -f $name)
    $full = $cmd + "; printf 'D''IAG_DONE\n'"
    $log = Join-Path $logs ("board_{0}.log" -f $name)
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $runner `
        -Cmd $full -Until 'DIAG_DONE' -MaxMs 1800000 -OutFile $log 2>&1 |
        ForEach-Object { $_.ToString() }
    $hdr = @(
        "# command: tools/debug/run_board_suite.ps1 -> $name",
        "# bitstream: $Bitstream   boot.bin: sha256 $BootSha",
        "# commit: $sha   VERSION=0x00040301",
        '# date: 2026-10-24',
        ''
    )
    if (Test-Path $log) {
        $body = [IO.File]::ReadAllText($log)
        [IO.File]::WriteAllText($log, (($hdr -join "`n") + $body), (New-Object Text.UTF8Encoding $false))
    }
    $out | Where-Object { $_ -match 'RESULT|PASS|FAIL|OK|VERDICT|marked|round|T[1-5]|P[1-3]|loss=|retries|giveup|occ=|Overall' } |
        Select-Object -Last 10 | ForEach-Object { '  ' + $_.Trim().Substring(0, [Math]::Min(150, $_.Trim().Length)) }
    Write-Host ''
}
