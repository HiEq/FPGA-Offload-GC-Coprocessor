# ============================================================
# serial_push_image.ps1 - replace a file on the card over the serial console
#
#   powershell -File tools\serial_push_image.ps1 -Src artifacts\BOOT.BIN
#   powershell -File tools\serial_push_image.ps1 -Src artifacts\BOOT.BIN -NoSwap
#   powershell -File tools\serial_push_image.ps1 -Src artifacts\image.ub -Remote /boot/image.ub
#
# Why this exists: the host has no card reader, so the card is updated from the
# board itself.  The file is gzipped on the host (BOOT.BIN compresses ~8x), cut
# into chunks, base64-encoded and streamed as ASCII text.  Per chunk the board
# runs:
#
#   dd bs=1 count=<chars> of=part.b64 < /dev/ttyPS0
#   openssl base64 -d -in part.b64 -out part
#
# `dd` reads exactly the number of base64 characters sent, so the receiver ends
# by itself.  This is the only route that works on both images: BusyBox `head`
# has no -c, the fogccc image has no `base64`, and stty raw on its console is
# not reliable (binary into it corrupts the line discipline and kills the
# shell).  A watchdog kills a dd whose sender died, so a failed attempt cannot
# wedge the console.  Every chunk is checked by md5 and the rebuilt file by
# sha256; the previous file is kept as <Remote>.bak and the swap is a rename.
# ============================================================
param(
    [Parameter(Mandatory=$true)][string]$Src,
    [string]$Remote = '/boot/BOOT.BIN',
    [int]$ChunkKB = 256,
    [string]$Port = 'auto',
    [switch]$NoSwap
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'serial-session.ps1')

if (-not (Test-Path $Src)) { throw "not found: $Src" }
$Src = (Resolve-Path $Src).Path
$partDir = '/tmp/up'
$stage = "$Remote.new"

function Sha256([string]$p) { (Get-FileHash -Algorithm SHA256 -Path $p).Hash.ToLower() }
function Md5([string]$p) { (Get-FileHash -Algorithm MD5 -Path $p).Hash.ToLower() }

$ms1 = [int][TimeSpan]::FromSeconds(1).TotalMilliseconds
$ms20 = [int][TimeSpan]::FromSeconds(20).TotalMilliseconds
$ms30 = [int][TimeSpan]::FromSeconds(30).TotalMilliseconds
$ms60 = [int][TimeSpan]::FromSeconds(60).TotalMilliseconds
$ms300 = [int][TimeSpan]::FromSeconds(300).TotalMilliseconds
$ms600 = [int][TimeSpan]::FromSeconds(600).TotalMilliseconds
$ms900 = [int][TimeSpan]::FromSeconds(900).TotalMilliseconds

# --- host side: gzip, split, base64 each chunk, hash it ---------------------
$sw = [Diagnostics.Stopwatch]::StartNew()
$want = Sha256 $Src
$size = (Get-Item $Src).Length
$gz = Join-Path $env:TEMP ('push_image_' + [IO.Path]::GetFileName($Src) + '.gz')
$in = [IO.File]::OpenRead($Src)
$out = [IO.File]::Create($gz)
$gzStream = New-Object IO.Compression.GZipStream($out, [IO.Compression.CompressionLevel]::Optimal)
$in.CopyTo($gzStream)
$gzStream.Dispose(); $out.Dispose(); $in.Dispose()
"src : {0} ({1:N0} bytes) sha256 {2}" -f $Src, $size, $want
"gzip: {0:N0} bytes" -f (Get-Item $gz).Length

$raw = [IO.File]::ReadAllBytes($gz)
$chunkSize = $ChunkKB * 1KB
$n = [int][Math]::Ceiling($raw.Length / $chunkSize)
$parts = @()
$partsDir = Join-Path $env:TEMP 'push_image_parts'
if (Test-Path $partsDir) { Remove-Item $partsDir -Recurse -Force }
New-Item -ItemType Directory -Path $partsDir | Out-Null
for ($i = 0; $i -lt $n; $i++) {
    $off = $i * $chunkSize
    $len = [Math]::Min($chunkSize, $raw.Length - $off)
    $slice = New-Object byte[] $len
    [Array]::Copy($raw, $off, $slice, 0, $len)
    $bin = Join-Path $partsDir ('p{0:d3}.bin' -f $i)
    [IO.File]::WriteAllBytes($bin, $slice)
    $text = [Convert]::ToBase64String($slice, [Base64FormattingOptions]::InsertLineBreaks).Replace("`r`n", "`n") + "`n"
    $txt = Join-Path $partsDir ('p{0:d3}.b64' -f $i)
    [IO.File]::WriteAllText($txt, $text, (New-Object Text.UTF8Encoding $false))
    $parts += [pscustomobject]@{
        Index = $i; Bin = $bin; Text = $txt; Chars = $text.Length
        Md5 = (Md5 $bin); Bytes = $len
    }
}
"parts: {0} x <= {1:N0} bytes" -f $n, $chunkSize

# --- serial plumbing --------------------------------------------------------
$s = New-BoardSerialSession -Port $Port
$sp = $s.Sp
function Read-Until([string]$pat, [int]$maxMs) {
    $deadline = (Get-Date).AddMilliseconds($maxMs)
    while ((Get-Date) -lt $deadline) {
        try {
            $c = $sp.ReadExisting()
            if ($c) { [void]$s.Sb.Append($c) }
        } catch {}
        if ($s.Sb.Length -gt 0 -and $s.Sb.ToString() -match $pat) { return $s.Sb.ToString() }
        Start-Sleep -Milliseconds 15
    }
    return $s.Sb.ToString()
}
function Send([string]$text) {
    $b = [Text.Encoding]::ASCII.GetBytes($text)
    $off = 0
    while ($off -lt $b.Length) {
        $len = [Math]::Min(4KB, $b.Length - $off)
        $sp.Write($b, $off, $len)
        $off += $len
    }
}

try {
    # Reach a root shell by reading only: a byte inside U-Boot's bootdelay
    # aborts autoboot.  Only after 2 s of silence do we send one CR.
    $deadline = (Get-Date).AddSeconds(90)
    $nudged = $false
    $shell = $false
    $seenLogin = $false
    $sentBoot = $false
    while ((Get-Date) -lt $deadline) {
        [void](Read-Until '[\s\S]' $ms1)
        $buf = $s.Sb.ToString()
        if ($buf -match 'Zynq>' -and -not $sentBoot) { Send "boot`n"; $sentBoot = $true; continue }
        if ($buf -match 'root@[^\r\n]*[#$]') { $shell = $true; break }
        if (-not $seenLogin -and $buf -match 'login:') { Send "root`n"; $seenLogin = $true; continue }
        if (-not $nudged -and $buf.Length -eq 0 -and -not $seenLogin) { Send "`n"; $nudged = $true }
    }
    if (-not $shell) { throw 'no root shell on the console' }
    "shell: reached"

    Send "stty -echo`n"
    Send ("rm -rf {0}; mkdir -p {0}; printf 'PUSH_''READY\n'`n" -f $partDir)
    if (-not (Read-Until 'PUSH_READY' $ms30)) { throw 'board did not acknowledge' }

    foreach ($pt in $parts) {
        $i = $pt.Index
        $ok = $false
        for ($try = 1; $try -le 3 -and -not $ok; $try++) {
            $t0 = $sw.Elapsed.TotalSeconds
            # dd reads exactly the base64 characters we send, then the pipeline
            # decodes and reports.  The watchdog kills a dd whose sender died.
            Send ("set +m; dd bs=1 count={0} of={2}/p{1:d3}.b64 < /dev/ttyPS0 2>/dev/null & DP=`$!; ( sleep 120; kill `$DP 2>/dev/null ) & WP=`$!; wait `$DP; kill `$WP 2>/dev/null; openssl base64 -d -in {2}/p{1:d3}.b64 -out {2}/part{1:d3}; md5sum {2}/part{1:d3}; stat -c %s {2}/part{1:d3}; printf 'PA''RT{1:d3}_OK\n'`n" -f $pt.Chars, $i, $partDir)
            Start-Sleep -Milliseconds 400
            Send ([IO.File]::ReadAllText($pt.Text))
            if (-not (Read-Until ("PART{0:d3}_OK" -f $i) $ms600)) { throw ("part {0}: timeout" -f $i) }
            $r = $s.Sb.ToString()
            $md5m = [regex]::Matches($r, '[0-9a-f]{32}\s+\S+')
            $md5line = if ($md5m.Count) { $md5m[$md5m.Count - 1].Value } else { $null }
            $sizem = [regex]::Matches($r, '(?m)^\s*(\d+)\s*$')
            $sizeLine = if ($sizem.Count) { $sizem[$sizem.Count - 1].Groups[1].Value } else { $null }
            $ok = ($md5line -and $md5line.StartsWith($pt.Md5) -and $sizeLine -and [int]$sizeLine -eq $pt.Bytes)
            "  part {0:d3} try {1}: {2:N0} bytes {3} ({4:n1}s)" -f $i, $try, $pt.Bytes, $(if ($ok) { 'ok' } else { 'MISMATCH' }), ($sw.Elapsed.TotalSeconds - $t0)
        }
        if (-not $ok) { throw ("part {0} failed after 3 tries" -f $i) }
    }

    Send ("cat {0}/part* | gzip -dc > {1}; sha256sum {1}; printf 'S''TAGE_END\n'`n" -f $partDir, $stage)
    $r = Read-Until 'STAGE_END' $ms900
    $ham = [regex]::Matches($r, '[0-9a-f]{64}\s+\S+')
    $h = if ($ham.Count) { $ham[$ham.Count - 1].Value } else { $null }
    if (-not $h) { throw ("no sha256 for the staged file: {0}" -f $r) }
    $got = ($h -split '\s+')[0].ToLower()
    "stage: sha256 {0}" -f $got
    if ($got -ne $want) { throw ("staged sha256 mismatch: board {0} host {1}" -f $got, $want) }

    if ($NoSwap) {
        Send ("printf 'S''WAP_SKIPPED\n'`n")
        [void](Read-Until 'SWAP_SKIPPED' $ms20)
        "RESULT: staged only  {0}  (previous image untouched)" -f $stage
    } else {
        # Keep the previous image next to the new one; the rename is on the same
        # filesystem, so BOOT.BIN is either the old or the new file, never a mix.
        Send ("if [ -e {0} ]; then cp -f {0} {0}.bak; fi; mv -f {1} {0}; sync; sha256sum {0}; printf 'S''WAP_END\n'`n" -f $Remote, $stage)
        $r = Read-Until 'SWAP_END' $ms300
        $ham = [regex]::Matches($r, '[0-9a-f]{64}\s+\S+')
        $h = if ($ham.Count) { $ham[$ham.Count - 1].Value } else { $null }
        if (-not $h) { throw ("no sha256 after the swap: {0}" -f $r) }
        $got2 = ($h -split '\s+')[0].ToLower()
        "installed: sha256 {0}" -f $got2
        if ($got2 -ne $want) { throw ("installed sha256 mismatch: board {0} host {1}" -f $got2, $want) }
        "RESULT: OK  {0} -> {1}  sha256 {2}  ({3:n1}s)" -f (Split-Path $Src -Leaf), $Remote, $got2, $sw.Elapsed.TotalSeconds
        "next: reboot the board to load the new image (the FSBL reconfigures the PL on every boot)"
        Send ("ls -l {0} {0}.bak 2>/dev/null; rm -rf {1}; printf 'PUSH_''DONE\n'`n" -f $Remote, $partDir)
        [void](Read-Until 'PUSH_DONE' $ms60)
    }
}
finally {
    try { Send "stty sane`n" } catch {}
    Close-BoardSerialSession -Session $s
}
