# Negative control for the hand-over TBs: run them against the PRE-FIX RTL.
# Copies rtl/ to a scratch dir, restores gc_top.v / gc_axi_read.v from the
# parent of the fix commit, and expects every TB to report [FAIL].
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$cache = Join-Path $env:TEMP 'fogccc_neg_handover'
if (Test-Path $cache) { Remove-Item $cache -Recurse -Force }
New-Item -ItemType Directory -Path $cache | Out-Null

# 9f54420 is the pre-fix tree (identical to the remote 3ee7b03 tree).
& git -C $root archive --format=tar -o "$cache\rtl.tar" 9f54420 rtl
& "$env:SystemRoot\System32\tar.exe" -xf "$cache\rtl.tar" -C $cache
foreach ($f in 'gc_top.v', 'gc_axi_read.v') {
    $a = (Get-FileHash "$cache\rtl\$f" -Algorithm SHA256).Hash
    $b = (Get-FileHash (Join-Path $root "rtl\$f") -Algorithm SHA256).Hash
    if ($a -eq $b) { throw "negative control is using the FIXED $f" }
}

Push-Location $cache
try {
    & "$env:VIVADO_BIN\xvlog.bat" -sv `
        (Join-Path $cache 'rtl\gc_top.v'), (Join-Path $cache 'rtl\gc_mark_engine.v'),
        (Join-Path $cache 'rtl\gc_axi_read.v'), (Join-Path $cache 'rtl\gc_bitmap.v'),
        (Join-Path $cache 'rtl\gc_queue.v'), (Join-Path $cache 'rtl\gc_freelist.v'),
        (Join-Path $cache 'rtl\gc_dirty_fifo.v'), (Join-Path $cache 'rtl\gc_regs.v'),
        (Join-Path $root 'sim\axi_proto_check.v'),
        (Join-Path $root 'sim\tb_flush_data.v'),
        (Join-Path $root 'sim\tb_stale_ar_flush.v'),
        (Join-Path $root 'sim\tb_start_while_busy.v') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }

    $log = Join-Path $root 'tools\logs\xsim_handover_neg_20261024.log'
    $sha = (& git -C $root rev-parse --short HEAD).Trim()
    $lines = @(
        '# command: pre-fix rtl (gc_top.v/gc_axi_read.v from dd79355^) + the three hand-over TBs',
        '# bitstream: n/a (simulation negative control)',
        "# commit: $sha   VERSION=0x00040300",
        '# date: 2026-10-24',
        '# expectation: every TB reports [FAIL] -- a guard that cannot fail is not a guard',
        ''
    )
    foreach ($tb in 'tb_flush_data', 'tb_stale_ar_flush', 'tb_start_while_busy') {
        & "$env:VIVADO_BIN\xelab.bat" $tb -s $tb --mt 8 | Out-Null
        if ($LASTEXITCODE -ne 0) { $lines += "=== $tb ==="; $lines += 'XELAB FAILED'; continue }
        $out = & "$env:VIVADO_BIN\xsim.bat" $tb -R 2>&1 | ForEach-Object { $_.ToString() }
        $lines += "=== $tb ==="
        $lines += ($out | Where-Object { $_ -match '\[FAIL\]|PASS|ERROR' })
    }
    [IO.File]::WriteAllText($log, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
    $lines | Where-Object { $_ -match '\[FAIL\]|^===|XELAB' } | ForEach-Object { '  ' + $_.Trim() }
}
finally { Pop-Location }
