# ============================================================
# serial_push_image.ps1 - replace a file on the card over the serial console
#
#   powershell -File tools\serial_push_image.ps1 -Src artifacts\BOOT.BIN
#   powershell -File tools\serial_push_image.ps1 -Src artifacts\BOOT.BIN -NoSwap
#   powershell -File tools\serial_push_image.ps1 -Src artifacts\image.ub -Remote /boot/image.ub
#
# Why this exists: the host has no card reader, so the card is updated from the
# board itself.  The file is gzipped on the host (BOOT.BIN compresses ~8x),
# streamed as raw bytes into `head -c <n>` on the board, every chunk is checked
# by md5 and the rebuilt file by sha256.  Only then is it swapped into place;
# the previous file is kept as <Remote>.bak.
#
# Route used, per chunk:  stty raw -echo; head -c N > part; stty sane
# A base64 heredoc through the shell is ~6x slower (one line at a time), which
# is why this tool streams raw bytes instead.  ~11.5 KB/s at 115200 baud;
# a 18.6 MB BOOT.BIN takes ~3.5 min.
#
# Preconditions: the board is booted and sitting at a root shell.  Do not run
# this while the board is booting.
# ============================================================
param(
    [Parameter(Mandatory=$true)][string]$Src,
    [string]$Remote = '/boot/BOOT.BIN',
    [int]$ChunkKB = 512,
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

# --- host side: gzip once, split into chunks, hash every chunk --------------
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
$chunkSize = $ChunkKB * 1024
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
    $parts += [pscustomobject]@{ Index = $i; Bin = $bin; Md5 = (Md5 $bin); Bytes = $len }
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
        $len = [Math]::Min(4096, $b.Length - $off)
        $sp.Write($b, $off, $len)
        $off += $len
    }
}
function Send-Bytes([byte[]]$b) {
    $off = 0
    while ($off -lt $b.Length) {
        $len = [Math]::Min(4096, $b.Length - $off)
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
        [void](Read-Until '[\s\S]' 1000)
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
    if (-not (Read-Until 'PUSH_READY' 30000)) { throw 'board did not acknowledge' }

    foreach ($pt in $parts) {
        $i = $pt.Index
        $ok = $false
        for ($try = 1; $try -le 3 -and -not $ok; $try++) {
            $t0 = $sw.Elapsed.TotalSeconds
            Send ("stty -echo; printf 'G''O{1:d3}\n'; stty raw; head -c {0} > {2}/p{1:d3}; stty sane; stty -echo; printf 'PA''RT{1:d3}_OK\n'`n" -f $pt.Bytes, $i, $partDir)
            if (-not (Read-Until ("GO{0:d3}" -f $i) 30000)) { throw ("part {0}: no GO" -f $i) }
            # GO is printed just before `stty raw` runs; give it a beat so the
            # first bytes are not processed by the cooked line discipline.
            Start-Sleep -Milliseconds 250
            Send-Bytes ([IO.File]::ReadAllBytes($pt.Bin))
            if (-not (Read-Until ("PART{0:d3}_OK" -f $i) 600000)) { throw ("part {0}: timeout" -f $i) }
            Send ("md5sum {2}/p{1:d3}; stat -c %s {2}/p{1:d3}; printf 'P''{1:d3}_END\n'`n" -f 0, $i, $partDir)
            $r = Read-Until ("P{0:d3}_END" -f $i) 30000
            $md5m = [regex]::Matches($r, '[0-9a-f]{32}\s+\S+')
            $md5line = if ($md5m.Count) { $md5m[$md5m.Count - 1].Value } else { $null }
            $sizem = [regex]::Matches($r, '(?m)^\s*(\d+)\s*$')
            $sizeLine = if ($sizem.Count) { $sizem[$sizem.Count - 1].Groups[1].Value } else { $null }
            $ok = ($md5line -and $md5line.StartsWith($pt.Md5) -and $sizeLine -and [int]$sizeLine -eq $pt.Bytes)
            "  part {0:d3} try {1}: {2:N0} bytes {3} ({4:n1}s)" -f $i, $try, $pt.Bytes, $(if ($ok) { 'ok' } else { 'MISMATCH' }), ($sw.Elapsed.TotalSeconds - $t0)
        }
        if (-not $ok) { throw ("part {0} failed after 3 tries" -f $i) }
    }

    Send ("cat {0}/p* | gzip -dc > {1}; sha256sum {1}; printf 'S''TAGE_END\n'`n" -f $partDir, $stage)
    $r = Read-Until 'STAGE_END' 900000
    $ham = [regex]::Matches($r, '[0-9a-f]{64}\s+\S+')
    $h = if ($ham.Count) { $ham[$ham.Count - 1].Value } else { $null }
    if (-not $h) { throw ("no sha256 for the staged file: {0}" -f $r) }
    $got = ($h -split '\s+')[0].ToLower()
    "stage: sha256 {0}" -f $got
    if ($got -ne $want) { throw ("staged sha256 mismatch: board {0} host {1}" -f $got, $want) }

    if ($NoSwap) {
        Send ("printf 'S''WAP_SKIPPED\n'`n")
        [void](Read-Until 'SWAP_SKIPPED' 20000)
        "RESULT: staged only  {0}  (previous image untouched)" -f $stage
    } else {
        # Keep the previous image next to the new one; the rename is on the same
        # filesystem, so BOOT.BIN is either the old or the new file, never a mix.
        Send ("if [ -e {0} ]; then cp -f {0} {0}.bak; fi; mv -f {1} {0}; sync; sha256sum {0}; printf 'S''WAP_END\n'`n" -f $Remote, $stage)
        $r = Read-Until 'SWAP_END' 300000
        $ham = [regex]::Matches($r, '[0-9a-f]{64}\s+\S+')
        $h = if ($ham.Count) { $ham[$ham.Count - 1].Value } else { $null }
        if (-not $h) { throw ("no sha256 after the swap: {0}" -f $r) }
        $got2 = ($h -split '\s+')[0].ToLower()
        "installed: sha256 {0}" -f $got2
        if ($got2 -ne $want) { throw ("installed sha256 mismatch: board {0} host {1}" -f $got2, $want) }
        "RESULT: OK  {0} -> {1}  sha256 {2}  ({3:n1}s)" -f (Split-Path $Src -Leaf), $Remote, $got2, $sw.Elapsed.TotalSeconds
        "next: reboot the board to load the new image (the FSBL reconfigures the PL on every boot)"
        Send ("ls -l {0} {0}.bak 2>/dev/null; rm -rf {1}; printf 'PUSH_''DONE\n'`n" -f $Remote, $partDir)
        [void](Read-Until 'PUSH_DONE' 60000)
    }
}
finally {
    try { Send "stty sane`n" } catch {}
    Close-BoardSerialSession -Session $s
}


