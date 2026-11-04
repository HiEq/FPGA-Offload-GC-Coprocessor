param(
    [string]$Port = 'auto',
    [switch]$Build,
    [switch]$NoPush
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = (Resolve-Path (Join-Path $here '..\..')).Path
$bin = Join-Path $root 'artifacts\userdata\bin\verify_c_build'
$exec = Join-Path $here 'board-exec.ps1'
$push = Join-Path $here 'board-push.ps1'
$logDir = Join-Path $root 'tools\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

if ($Build -or -not (Test-Path $bin)) {
    $wslBuild = '/mnt/' + $root.Substring(0,1).ToLower() + $root.Substring(2).Replace('\','/') + '/csrc/build_routes/build_c.sh'
    & wsl -d Ubuntu-22.04 -- bash "$wslBuild"
    if ($LASTEXITCODE -ne 0) { throw 'C build-route cross-build failed' }
}
if (-not (Test-Path $bin)) { throw "missing $bin" }

if (-not $NoPush) {
    & $push -Port $Port -Src $bin -Dest '/tmp/verify_c_build'
}

$out = & $exec -Port $Port -User root -LoginWaitMs 20000 `
    -Cmd 'chmod +x /tmp/verify_c_build; /tmp/verify_c_build' -WaitMs 90000 2>&1

# Fixed log name: a rerun replaces it, the previous content stays in git history.
$log = Join-Path $logDir 'board_build_routes_c.log'
$boot = (Select-String -Path (Join-Path $root 'artifacts\SHA256SUMS.release') -Pattern 'BOOT\.BIN$' |
    Select-Object -First 1).Line -replace '\s+BOOT\.BIN$', ''
$commit = (& git -C $root rev-parse --short HEAD 2>$null)
$header = @(
    '# command: tools/build_routes/run_c_build.ps1',
    ('# bitstream: 6D4792448135C3796E3CAA1AD86EEA30' + '   boot.bin: ' + $boot),
    ('# commit: ' + $commit),
    ('# date: ' + (Get-Date -Format 'yyyy-MM-dd'))
)
$text = ($header -join "`n") + "`n" + (($out | ForEach-Object { "$_" }) -join "`n") + "`n"
[IO.File]::WriteAllText($log, $text, (New-Object Text.UTF8Encoding $false))
$out | ForEach-Object { Write-Host $_ }

$joined = $out -join "`n"
if ($joined -notmatch 'C_BUILD_RESULT OK') {
    Write-Host ('FAIL: C_BUILD_RESULT OK not found (log: {0})' -f $log)
    exit 1
}
Write-Host ('PASS: C graph-build route (log: {0})' -f $log)
