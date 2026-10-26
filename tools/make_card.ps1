# Regenerate the card-side copies under artifacts/userdata from their sources.
# Binaries (bin/test_main, py/libfogccc.so, ko/fogccc-irq.ko) are build
# outputs and are not touched here.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$dst  = Join-Path $root 'artifacts\userdata'

Copy-Item (Join-Path $root 'tools\tests\gc_test.py') (Join-Path $dst 'gc_test.py') -Force
Copy-Item (Join-Path $root 'tools\tests\side_table_test.py') (Join-Path $dst 'tests\side_table_test.py') -Force
foreach ($f in 'abort_sweep.py', 'abort_test.py', 'done_race_test.py', 'freelist_contract_test.py', 'dirty_set_test.py', 'dirty_concurrent_test.py', 'dirty_overflow_test.py', 'dirty_leftover_test.py', 'dirty_state.py', 'ctrl_spill_test.py', 'freelist_n4096_test.py', 'dirty_api_test.py', 'three_way.py', 'barrier_verify_test.py', 'regs_aww_board_test.py') {
    Copy-Item (Join-Path $root "tools\tests\$f") (Join-Path $dst "tests\$f") -Force
}
Copy-Item (Join-Path $root 'csrc\py_bfs.py') (Join-Path $dst 'tests\py_bfs.py') -Force
Copy-Item (Join-Path $root 'tools\tests\irq_drv_test.sh') (Join-Path $dst 'tests\irq_drv_test.sh') -Force
Copy-Item (Join-Path $root 'python\fogccc.py') (Join-Path $dst 'py\fogccc.py') -Force

Get-ChildItem $dst -Recurse -Directory -Filter '__pycache__' |
    Remove-Item -Recurse -Force

Write-Host 'card copies refreshed under artifacts/userdata'
