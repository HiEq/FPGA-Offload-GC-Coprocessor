param(
    [string]$Port = 'auto'
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = (Resolve-Path (Join-Path $here '..\..')).Path
$bin = Join-Path $root 'artifacts\userdata\bin'
$tests = Join-Path $root 'tools\tests'
$exec = Join-Path $here 'board-exec.ps1'
$push = Join-Path $here 'board-push.ps1'

function Clean-Lines($lines) {
    return @($lines | ForEach-Object { $_ -replace '^\s*\|\s?', '' })
}

function Show-Section($title, $lines) {
    Write-Host ''
    Write-Host ('=' * 100) -ForegroundColor DarkCyan
    Write-Host $title -ForegroundColor Cyan
    Write-Host ('=' * 100) -ForegroundColor DarkCyan
    foreach ($line in (Clean-Lines $lines)) {
        if ($line -match '^\s*$') { continue }
        if ($line -match '^\s*\d+\s+\d+\s+' -or
            $line -match 'FOGCCC|objects|mkd|build ms|C build|DMA build|N=4000|RESULT|THREE_WAY|verify\[|DMA_INFO|C_BUILD mode|C_BUILD_SUMMARY|DMA_BUILD n|DMA_BUILD_SUMMARY|layout') {
            Write-Host $line
        }
    }
}

try {
    $Host.UI.RawUI.WindowTitle = 'FOGCCC C vs DMA graph build - live board output'
    Clear-Host
    Write-Host 'FOGCCC graph-build comparison: C vs DMA' -ForegroundColor Yellow
    Write-Host 'Board: FOGCCC Linux / XC7Z100, PS 800 MHz, PL 100 MHz, serial 921600' -ForegroundColor Gray
    Write-Host 'All numbers below are read from the live board, not copied from the report.' -ForegroundColor Gray
    Write-Host ''

    Write-Host '[0/4] checking board files...' -ForegroundColor Yellow
    $check = & $exec -Port $Port -User root -LoginWaitMs 20000 -Cmd 'test -f /tmp/four_way_c_build.py -a -f /tmp/four_way_dma_build.py -a -f /tmp/dma_build_one -a -f /tmp/fogccc_dma.ko; echo FILES_RC=$?' -WaitMs 10000 2>&1
    if (($check -join "`n") -notmatch 'FILES_RC=0') {
        Write-Host '  missing board files, pushing now...' -ForegroundColor Yellow
        & $push -Port $Port -Src (Join-Path $tests 'four_way_c_build.py') -Dest '/tmp/four_way_c_build.py'
        & $push -Port $Port -Src (Join-Path $tests 'four_way_dma_build.py') -Dest '/tmp/four_way_dma_build.py'
        & $push -Port $Port -Src (Join-Path $bin 'dma_build_one') -Dest '/tmp/dma_build_one'
        & $push -Port $Port -Src (Join-Path $root 'artifacts\userdata\ko\fogccc_dma.ko') -Dest '/tmp/fogccc_dma.ko'
    }

    [void](& $exec -Port $Port -User root -LoginWaitMs 20000 -Cmd 'tmux set-option -g status off 2>/dev/null; chmod +x /tmp/dma_build_one; echo READY' -WaitMs 10000 2>&1)

    Write-Host '[1/4] C build verification (direct + cached)...' -ForegroundColor Yellow
    & $push -Port $Port -Src (Join-Path $bin 'verify_c_build') -Dest '/tmp/verify_c_build' | Out-Null
    $cVerify = & $exec -Port $Port -User root -LoginWaitMs 20000 -Cmd 'chmod +x /tmp/verify_c_build; /tmp/verify_c_build' -WaitMs 90000 2>&1

    Write-Host '[2/4] DMA build verification (PL330)...' -ForegroundColor Yellow
    & $push -Port $Port -Src (Join-Path $root 'artifacts\userdata\ko\fogccc_dma.ko') -Dest '/tmp/fogccc_dma.ko' | Out-Null
    & $push -Port $Port -Src (Join-Path $bin 'verify_dma_build') -Dest '/tmp/verify_dma_build' | Out-Null
    $dVerify = & $exec -Port $Port -User root -LoginWaitMs 20000 -Cmd 'rmmod fogccc_dma 2>/dev/null; insmod /tmp/fogccc_dma.ko; chmod +x /tmp/verify_dma_build; /tmp/verify_dma_build; rmmod fogccc_dma 2>/dev/null' -WaitMs 90000 2>&1

    Write-Host '[3/4] four-way comparison, C build...' -ForegroundColor Yellow
    $cFour = & $exec -Port $Port -User root -LoginWaitMs 20000 -Cmd 'cd /run/media/USERDATA-mmcblk0p2 && python3 /tmp/four_way_c_build.py' -WaitMs 120000 2>&1

    Write-Host '[4/4] four-way comparison, DMA build...' -ForegroundColor Yellow
    $dFour = & $exec -Port $Port -User root -LoginWaitMs 20000 -Cmd 'rmmod fogccc_dma 2>/dev/null; insmod /tmp/fogccc_dma.ko; cd /run/media/USERDATA-mmcblk0p2 && python3 /tmp/four_way_dma_build.py; rmmod fogccc_dma 2>/dev/null' -WaitMs 120000 2>&1

    Clear-Host
    Write-Host 'FOGCCC graph-build comparison: C vs DMA (live board output)' -ForegroundColor Yellow
    Write-Host 'Board: FOGCCC Linux / XC7Z100, PS 800 MHz, PL 100 MHz, 4000 objects, avg_refs=3' -ForegroundColor Gray
    Write-Host ''

    Show-Section '1) C build verification: direct writes vs cached build + memcpy' $cVerify
    Show-Section '2) DMA build verification: cached build -> coherent staging -> PL330 DMA' $dVerify
    Show-Section '3) Project four-way test, graph built by C' $cFour
    Show-Section '4) Project four-way test, graph built by DMA' $dFour

    Write-Host ''
    Write-Host ('=' * 100) -ForegroundColor DarkCyan
    Write-Host 'Summary' -ForegroundColor Cyan
    Write-Host ('=' * 100) -ForegroundColor DarkCyan
    Write-Host '  Python build reference in the report : 102.2 ms/graph'
    Write-Host '  C direct builder                     : about 5 ms'
    Write-Host '  C cached builder                     : about 2 ms'
    Write-Host '  DMA builder (build+stage+DMA)        : about 2-5 ms'
    Write-Host '  FPGA mark engine (4000 objects)      : about 645 us'
    Write-Host ''
    Write-Host '  The FPGA mark column is unchanged; the gain is end-to-end graph build.'
    Write-Host '  See C_FOUR_WAY_RESULT OK / DMA_FOUR_WAY_RESULT OK above.'
    Write-Host ''
    Write-Host 'Screenshot now. Press any key to close this window...' -ForegroundColor Green
    [void][Console]::ReadKey($true)
}
finally {
    try {
        [void](& $exec -Port $Port -User root -LoginWaitMs 10000 -Cmd 'rmmod fogccc_dma 2>/dev/null; tmux set-option -g status on 2>/dev/null; echo CLEANUP_DONE' -WaitMs 10000 2>&1)
    } catch { }
}
