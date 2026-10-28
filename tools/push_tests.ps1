# push_tests.ps1 - push every board-side test script to the card as a SET.
#
#   powershell -ExecutionPolicy Bypass -File tools\push_tests.ps1 [-Port COMx] [-DataDir <path>]
#
# The card's tests/ is a copy of this repo's tools/tests/ (the released zip
# layout).  Pushing only one file is not enough: a test that does
# `import side_table_test` fails with ModuleNotFoundError when the sibling module
# on the card still has its old name.  (Observed 2026-10-22/23: the chain hung
# waiting for a sentinel, and a stale card copy of abort_sweep.py reported a
# false FAIL, because a partial push / a second copy location was in use.)
#
# Each file is pushed with serial_push_chunked.ps1 (own serial session + per-chunk md5).
param(
    [string]$Port = 'auto',
    [string]$DataDir = '/run/media/USERDATA-mmcblk0p2'
)
$ErrorActionPreference = 'Stop'

$push  = Join-Path $PSScriptRoot 'serial_push_chunked.ps1'
$tests = Join-Path $PSScriptRoot 'tests'

$jobs = @()
Get-ChildItem $tests -File | Where-Object { $_.Extension -in '.py', '.sh' } | Sort-Object Name | ForEach-Object {
    $jobs += ,@($_.FullName, "$DataDir/tests/$($_.Name)")
}
# the ctypes binding the tests import from py/
$jobs += ,@((Join-Path $PSScriptRoot '..\artifacts\userdata\py\fogccc.py'), "$DataDir/py/fogccc.py")

# fpga_vs_python.sh expects fpga_vs_python.py at the partition root, not in tests/
$jobs += ,@((Join-Path $tests 'fpga_vs_python.py'), "$DataDir/fpga_vs_python.py")

# Root-level card scripts + the data-partition README ship inside the release zip,
# so a card written from an older zip keeps stale copies (observed: fpga_vs_python_repeat.sh
# still printed the removed comparison wording).  Push them from artifacts/userdata.
$art = Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts\userdata'
Get-ChildItem $art -File | Where-Object { $_.Name -like 'run_*.sh' -or $_.Name -eq 'README.txt' } | Sort-Object Name | ForEach-Object {
    $jobs += ,@($_.FullName, "$DataDir/$($_.Name)")
}

foreach ($j in $jobs) {
    Write-Host ("--- push {0} ---" -f (Split-Path $j[0] -Leaf))
    & $push -Src $j[0] -Dest $j[1] -Port $Port | Out-Host
}

Write-Host ("push_tests: done ({0} files)" -f $jobs.Count)