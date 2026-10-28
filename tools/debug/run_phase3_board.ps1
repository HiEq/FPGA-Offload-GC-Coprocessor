# ============================================================
# run_phase3_board.ps1 - Phase 3A/3B board verification chain
#
#   1. test_main            (C suite, v4.2 pairing)
#   2. serial_phase2.ps1    (Phase 2 regression: side-table + fpga_vs_python sweep)
#   3. freelist_contract    (Phase 2 contract negative controls)
#   4. dirty_set_test       (Phase 3A: incremental epochs + oracle + no-barrier neg)
#   5. dirty_concurrent     (Phase 3B: concurrent mutator + remark + stress)
#
# Each step's full output goes to tools\logs\board_phase3_<step>.log; the
# console shows only the verdict lines.
# ============================================================
param(
    [string]$DataDir = '/run/media/USERDATA-mmcblk0p2'
)
$ErrorActionPreference = 'Continue'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$runner = Join-Path $root 'tools\debug\diag_run.ps1'
$logs = Join-Path $root 'tools\logs'

function Run([string]$name, [string]$cmd, [string]$until) {
    Write-Host ("=== {0} ===" -f $name)
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $runner `
        -Cmd $cmd -Until $until -MaxMs 1200000 `
        -OutFile (Join-Path $logs ("board_phase3_{0}.log" -f $name)) 2>&1
    $out | Select-String -Pattern 'Test [0-9]|ALL PASS|PASS|FAIL|OK|RESULT|marked|free|oracle|round|stress|neg|VERSION|MAGIC|eye' |
        ForEach-Object { '  ' + $_.Line.Trim() }
    Write-Host ''
}

Run 'test_main' ("cd {0} && chmod +x bin/test_main && ./bin/test_main; printf 'T''M=%s\n' `$?" -f $DataDir) 'TM='

Write-Host '=== regression: serial_phase2 ==='
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\serial_phase2.ps1') 2>&1 |
    Select-String -Pattern 'SIDE_TABLE|PASSED|RESULT|RC=|raw:' | ForEach-Object { '  ' + $_.Line.Trim() }
Write-Host ''

Run 'freelist_contract' ("cd {0} && python3 -u tests/freelist_contract_test.py" -f $DataDir) 'DIAG_DONE'
Run 'dirty_set'         ("cd {0} && python3 -u tests/dirty_set_test.py" -f $DataDir) 'DIAG_DONE'
Run 'dirty_concurrent'  ("cd {0} && python3 -u tests/dirty_concurrent_test.py" -f $DataDir) 'DIAG_DONE'
Run 'dirty_overflow'    ("cd {0} && python3 -u tests/dirty_overflow_test.py" -f $DataDir) 'DIAG_DONE'
Run 'ctrl_spill'        ("cd {0} && python3 -u tests/ctrl_spill_test.py" -f $DataDir) 'DIAG_DONE'

# Every step must leave the dirty FIFO empty: a leftover barrier record perturbs
# the next full mark (extra marks + q_tail != marked).  This is the check that
# was missing when test_main flaked (see AGENTS.md #18).
Write-Host '=== dirty FIFO state at the end (must be occ=0) ==='
$st = & powershell -NoProfile -ExecutionPolicy Bypass -File $runner `
    -Cmd ("cd {0} && python3 -u tests/dirty_state.py" -f $DataDir) -Until 'DIAG_DONE' -MaxMs 60000 2>&1
$line = ($st | Select-String -Pattern 'DIRTY_STATE' | Select-Object -Last 1)
Write-Host ('  ' + $(if ($line) { $line.Line.Trim() } else { 'DIRTY_STATE <no output>' }))

Write-Host 'PHASE3_BOARD_CHAIN_DONE'