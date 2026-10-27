param(
    [string]$Port = 'auto',
    [string]$DataDir = '/run/media/USERDATA-mmcblk0p2',
    [int]$N = 512,
    [int]$Seed = 12345,
    [int]$Trials = 8
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'serial-session.ps1')

$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
# Stable names: the docs cite this log by name, and a timestamped pair per run
# would just accumulate (see tools/logs/README.md).  The run time is written into
# the transcript header instead.
$outFile = Join-Path $logDir 'board_phase2_regression.log'
$rawFile = Join-Path $logDir 'board_phase2_regression.raw.log'
$transcript = New-Object System.Text.StringBuilder
$rawSections = New-Object System.Collections.Generic.List[string]

function Log([string]$text) {
    Write-Host $text
    [void]$transcript.AppendLine($text)
}

Log ("--- date: {0} ---" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# ---- push every board-side test script as a set (sibling imports must resolve) ----
Log "--- push tests ---"
& (Join-Path $PSScriptRoot 'push_tests.ps1') -Port $Port -DataDir $DataDir | Out-Host

# ---- run on the board ----
$s = New-BoardSerialSession -Port $Port
Log ("opened {0} @ {1}" -f $s.Port, $s.Baud)
Read-BoardSerial -Session $s -Ms 500
$s.Sp.Write("`r")
Read-BoardSerial -Session $s -Ms 1000

function Run-Cmd([string]$cmd, [string]$pattern, [int]$maxMs) {
    $from = $s.Sb.Length
    Write-BoardSerialLine -Session $s -Text $cmd -SettleMs 0
    [void](Read-BoardSerialUntil -Session $s -Pattern $pattern -MaxMs $maxMs -From $from)
    Read-BoardSerial -Session $s -Ms 500
    return $s.Sb.ToString($from, $s.Sb.Length - $from)
}

Log "--- side table positive ---"
$r1 = Run-Cmd "cd $DataDir && python3 -u tests/side_table_test.py --hw --n $N --seed $Seed; printf 'R''C=%s\n' `$?" 'RC=' 180000
$r1 -split '\r?\n' | Where-Object { $_ -match 'SIDE_TABLE|RC=' } | ForEach-Object { Log $_.Trim() }
$rawSections.Add("`n===== RAW: side table positive =====`n" + $r1)

Log "--- side table negative control ---"
$r2 = Run-Cmd "cd $DataDir && python3 -u tests/side_table_test.py --hw --neg --n $N --seed $Seed; printf 'N''EGRC=%s\n' `$?" 'NEGRC=' 180000
$r2 -split '\r?\n' | Where-Object { $_ -match 'SIDE_TABLE|NEGRC=' } | ForEach-Object { Log $_.Trim() }
$rawSections.Add("`n===== RAW: side table negative control =====`n" + $r2)

Log "--- gc_test sweep ---"
$r3 = Run-Cmd "cd $DataDir && python3 -u fpga_vs_python.py 4096 $Trials 2 --seed $Seed; printf 'G''CRC=%s\n' `$?" 'GCRC=' 1800000
$r3 -split '\r?\n' | Where-Object { $_ -match 'PASSED \(all invariants\)|GCRC=|ERROR' } | ForEach-Object { Log $_.Trim() }
$rawSections.Add("`n===== RAW: gc_test sweep =====`n" + $r3)

Close-BoardSerialSession -Session $s
[System.IO.File]::WriteAllText($outFile, $transcript.ToString())
[System.IO.File]::WriteAllText($rawFile, ($rawSections -join "`n"))
Log "transcript: $outFile"
Log "raw:        $rawFile"

$ok1 = ($r1 -match 'SIDE_TABLE_HW PASS')
$ok2 = ($r2 -match 'SIDE_TABLE_HW NEG-OK')
$ok3 = ($r3 -match 'PASSED \(all invariants\):\s*(\d+)/\1')
if ($ok1 -and $ok2 -and $ok3) {
    Log 'RESULT: PHASE2_PASS'
    exit 0
}
Log ("RESULT: PHASE2_FAIL  positive={0} neg={1} sweep={2}" -f $ok1, $ok2, $ok3)
exit 1