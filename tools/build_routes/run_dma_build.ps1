param(
    [string]$Port = 'auto',
    [switch]$Build,
    [switch]$NoPush,
    [switch]$KeepModule
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = (Resolve-Path (Join-Path $here '..\..')).Path
$bin = Join-Path $root 'artifacts\userdata\bin\verify_dma_build'
$module = Join-Path $root 'artifacts\userdata\ko\fogccc_dma.ko'
$exec = Join-Path $here 'board-exec.ps1'
$push = Join-Path $here 'board-push.ps1'
$logDir = Join-Path $root 'tools\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

if ($Build -or -not (Test-Path $bin) -or -not (Test-Path $module)) {
    $wslRoot = '/mnt/' + $root.Substring(0,1).ToLower() + $root.Substring(2).Replace('\','/')
    & wsl -d Ubuntu-22.04 -- bash "$wslRoot/csrc/build_routes/build_c.sh"
    if ($LASTEXITCODE -ne 0) { throw 'C build-route cross-build failed' }
    & wsl -d Ubuntu-22.04 -- bash "$wslRoot/csrc/build_routes/build_dma.sh"
    if ($LASTEXITCODE -ne 0) { throw 'DMA kernel module build failed' }
}
if (-not (Test-Path $bin)) { throw "missing $bin" }
if (-not (Test-Path $module)) { throw "missing $module" }

if (-not $NoPush) {
    & $push -Port $Port -Src $module -Dest '/tmp/fogccc_dma.ko'
    & $push -Port $Port -Src $bin -Dest '/tmp/verify_dma_build'
}

$finish = if ($KeepModule) { 'true' } else { 'rmmod fogccc_dma 2>/dev/null' }
$cmd = "rmmod fogccc_dma 2>/dev/null; insmod /tmp/fogccc_dma.ko && chmod +x /tmp/verify_dma_build && /tmp/verify_dma_build; echo DMA_RUN_RC=`$?; $finish"

$out = & $exec -Port $Port -User root -LoginWaitMs 20000 `
    -Cmd $cmd -WaitMs 90000 2>&1

# Fixed log name: a rerun replaces it, the previous content stays in git history.
$log = Join-Path $logDir 'board_build_routes_dma.log'
$boot = (Select-String -Path (Join-Path $root 'artifacts\SHA256SUMS.release') -Pattern 'BOOT\.BIN$' |
    Select-Object -First 1).Line -replace '\s+BOOT\.BIN$', ''
$commit = (& git -C $root rev-parse --short HEAD 2>$null)
$header = @(
    '# command: tools/build_routes/run_dma_build.ps1',
    ('# bitstream: 6D4792448135C3796E3CAA1AD86EEA30' + '   boot.bin: ' + $boot),
    ('# commit: ' + $commit),
    ('# date: ' + (Get-Date -Format 'yyyy-MM-dd'))
)
$text = ($header -join "`n") + "`n" + (($out | ForEach-Object { "$_" }) -join "`n") + "`n"
[IO.File]::WriteAllText($log, $text, (New-Object Text.UTF8Encoding $false))
$out | ForEach-Object { Write-Host $_ }

$joined = $out -join "`n"
if ($joined -notmatch 'DMA_BUILD_RESULT OK') {
    Write-Host ('FAIL: DMA_BUILD_RESULT OK not found (log: {0})' -f $log)
    exit 1
}
Write-Host ('PASS: DMA graph-build route (log: {0})' -f $log)
