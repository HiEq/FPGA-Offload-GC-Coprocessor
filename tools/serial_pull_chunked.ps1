# Pull a file from the board over the serial console in verified chunks.
#
# The console has no flow control, so each chunk carries its own md5 and a
# sentinel, and the board paces its output (a burst larger than the USB-serial
# buffer drops bytes).  A corrupted chunk is retried.  Usage:
#   powershell -ExecutionPolicy Bypass -File tools/serial_pull_chunked.ps1 `
#       -Remote /mnt/boot/BOOT.BIN -Local artifacts/BOOT.BIN -ChunkKB 512
param(
    [Parameter(Mandatory=$true)][string]$Remote,
    [Parameter(Mandatory=$true)][string]$Local,
    [int]$ChunkKB = 512,
    [int]$PaceLines = 32,
    [int]$PaceMs = 20,
    [string]$Port = 'auto',
    [int]$Baud = 921600,
    [int]$Retries = 4,
    [int]$MaxChunks = 0
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'serial-port.ps1')
$Port = Resolve-SerialPort $Port

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.Handshake = [System.IO.Ports.Handshake]::XOnXOff
$sp.ReadTimeout = 150000
$sp.WriteTimeout = 20000
$sp.DtrEnable = $true
$sp.ReadBufferSize = 1048576
$sp.Open()
Start-Sleep -Milliseconds 300
$sp.DiscardInBuffer()

function Send([string]$text) { $sp.Write($text + "`r") }

function WaitPrompt([int]$ms) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($ms)
    $sb = New-Object System.Text.StringBuilder
    $buf = New-Object byte[] 65536
    while ([DateTime]::UtcNow -lt $deadline) {
        try { $n = $sp.BaseStream.Read($buf, 0, $buf.Length) } catch { continue }
        if ($n -le 0) { continue }
        [void]$sb.Append([Text.Encoding]::ASCII.GetString($buf, 0, $n))
        if ($sb.ToString() -match '#\s*$') { return $sb.ToString() }
    }
    return $sb.ToString()
}

function PullChunk([int]$index, [string]$tmp) {
    $cmd = "dd if=$Remote bs=${ChunkKB}K skip=$index count=1 2>/dev/null of=/tmp/pullchunk.bin; " +
           "md5sum /tmp/pullchunk.bin; " +
           "openssl base64 -in /tmp/pullchunk.bin | { n=0; while read l; do echo `"`$l`"; " +
           "n=`$((n+1)); [ `$((n % $PaceLines)) -eq 0 ] && sleep $([double]$PaceMs / 1000); done; }; " +
           "echo __END__"
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        $sp.DiscardInBuffer()
        Send $cmd
        $ms = New-Object System.IO.MemoryStream
        $buf = New-Object byte[] 65536
        $tail = ''
        $deadline = [DateTime]::UtcNow.AddMinutes(10)
        while ([DateTime]::UtcNow -lt $deadline) {
            try { $n = $sp.BaseStream.Read($buf, 0, $buf.Length) } catch { break }
            if ($n -le 0) { continue }
            $ms.Write($buf, 0, $n)
            # Keep only the last 64 characters: ToArray() on the whole stream
            # every iteration is O(n^2) and drops bytes under backpressure.
            $tail += [Text.Encoding]::ASCII.GetString($buf, 0, $n)
            if ($tail.Length -gt 64) { $tail = $tail.Substring($tail.Length - 64) }
            if ($tail.Contains('__END__')) { break }
        }
        $raw = [Text.Encoding]::ASCII.GetString($ms.ToArray())
        # Drop terminal control sequences if a multiplexer is still running.
        $raw = $raw -replace "\x1b\[[0-9;?]*[A-Za-z]", "" -replace "\x1b\][^\x07]*\x07", ""
        $lines = $raw -split "`n" | ForEach-Object { $_.TrimEnd("`r") }
        $line = ($lines | Where-Object { $_ -match '^[0-9a-f]{32}\s+/tmp/pullchunk' } | Select-Object -First 1)
        if (-not $line) { continue }
        $want = ($line -split '\s+')[0]
        $body = ($lines | Where-Object { $_ -match '^[A-Za-z0-9+/=]+$' -and $_.Length -ge 4 }) -join ''
        try { $bytes = [Convert]::FromBase64String($body) } catch { continue }
        $md5 = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash($bytes)).Replace('-','').ToLower()
        if ($md5 -eq $want) {
            [IO.File]::WriteAllBytes($tmp, $bytes)
            return $bytes.Length
        }
        Write-Host "chunk $index attempt ${attempt}: md5 $md5 != $want ($($bytes.Length) bytes)"
    }
    throw "chunk $index failed after $Retries attempts"
}

Send 'stty -echo ixon ixoff'
[void](WaitPrompt 8000)

$tmp = [IO.Path]::GetTempFileName()
$out = New-Object System.IO.MemoryStream
$total = 0
for ($i = 0; ; $i++) {
    $n = PullChunk $i $tmp
    $bytes = [IO.File]::ReadAllBytes($tmp)
    $out.Write($bytes, 0, $bytes.Length)
    $total += $bytes.Length
    Write-Host ("chunk {0}: {1} bytes (total {2})" -f $i, $bytes.Length, $total)
    if ($MaxChunks -gt 0 -and $i + 1 -ge $MaxChunks) { break }
    if ($bytes.Length -lt ($ChunkKB * 1KB)) { break }
}
[IO.File]::WriteAllBytes($Local, $out.ToArray())
Remove-Item $tmp -Force
Write-Host ("wrote {0} ({1} bytes)" -f $Local, $total)
$sp.Close()
