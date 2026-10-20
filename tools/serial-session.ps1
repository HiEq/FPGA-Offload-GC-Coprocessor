# ============================================================
# serial-session.ps1 - shared serial plumbing for the host scripts
#
# Shared serial plumbing: open the port, pump bytes, chunked write, strip ANSI,
# print the tail. Used by serial_cmd.ps1 and serial_run_gc.ps1.
# Waits take a $From offset so a stale prompt in the buffer cannot satisfy a new wait.
#
# NOT used by serial-monitor.ps1, on purpose: that file is a byte-identical
# shared artifact with LINUX-FPGA\scripts\serial-monitor.ps1 (see its header) and
# has a different job (interactive console, key forwarding, clock injection).
# Do not "unify" it unless both repos change in the same commit.
#
# Port resolution lives in serial-port.ps1 (also shared with LINUX-FPGA).
#
# ASCII only: PowerShell 5.1 parses .ps1 with the ANSI code page unless the file
# has a UTF-8 BOM. Keeping this file pure ASCII means no BOM is needed.
# ============================================================

. (Join-Path $PSScriptRoot 'serial-port.ps1')

# Open the board port. Returns a session hashtable:
#   @{ Port; Baud; Sp; Sb }   Sp = SerialPort (or $null in buffer-only tests)
function New-BoardSerialSession {
    param(
        [string]$Port = 'auto',
        [int]$Baud = 115200
    )
    $Port = Resolve-SerialPort $Port
    $sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
    $sp.ReadBufferSize  = 65536
    $sp.WriteBufferSize = 65536
    $sp.ReadTimeout     = 200
    $sp.WriteTimeout    = 3000
    $sp.Open()
    return @{
        Port = $sp.PortName
        Baud = $Baud
        Sp   = $sp
        Sb   = (New-Object System.Text.StringBuilder)
    }
}

# Pump whatever arrives for Ms milliseconds into the session buffer.
function Read-BoardSerial {
    param($Session, [int]$Ms, [int]$PollMs = 15)
    if ($null -eq $Session.Sp) { return }
    $end = (Get-Date).AddMilliseconds($Ms)
    while ((Get-Date) -lt $end) {
        try { $c = $Session.Sp.ReadExisting(); if ($c) { [void]$Session.Sb.Append($c) } } catch {}
        Start-Sleep -Milliseconds $PollMs
    }
}

# Pump until Pattern matches in the buffer **after byte offset From**.
# The offset is the whole point: the buffer keeps the entire session (login
# banner, earlier commands), so without it an old prompt satisfies the pattern
# before the new command has produced a single byte.
# With no port attached (unit tests) it evaluates the buffer once and returns.
function Read-BoardSerialUntil {
    param($Session, [string]$Pattern, [int]$MaxMs, [int]$From = 0, [int]$PollMs = 15)
    $end = (Get-Date).AddMilliseconds($MaxMs)
    while ($true) {
        if ($Session.Sb.Length -gt $From) {
            $new = $Session.Sb.ToString($From, $Session.Sb.Length - $From)
            if ($new -match $Pattern) { return $true }
        }
        if ($null -eq $Session.Sp) { return $false }
        if ((Get-Date) -ge $end) { return $false }
        try { $c = $Session.Sp.ReadExisting(); if ($c) { [void]$Session.Sb.Append($c) } } catch {}
        Start-Sleep -Milliseconds $PollMs
    }
}

# Send one line in 16-byte chunks (the board's UART drops bursts otherwise).
function Write-BoardSerialLine {
    param($Session, [string]$Text, [int]$Chunk = 16, [int]$ChunkDelayMs = 30, [int]$SettleMs = 400)
    for ($i = 0; $i -lt $Text.Length; $i += $Chunk) {
        $n = [Math]::Min($Chunk, $Text.Length - $i)
        $Session.Sp.Write($Text.Substring($i, $n))
        Start-Sleep -Milliseconds $ChunkDelayMs
    }
    $Session.Sp.Write("`n")
    if ($SettleMs -gt 0) { Start-Sleep -Milliseconds $SettleMs }
}

# Send a command and wait for the shell prompt to come back.
# Returns $true if the prompt showed up within WaitMs.
function Invoke-BoardSerialCommand {
    param($Session, [string]$Text, [int]$WaitMs = 8000, [int]$PromptPollMs = 200,
          [switch]$Echo, [switch]$WarnOnTimeout)
    if ($Echo) { Write-Host ("> " + $Text) }
    $from = $Session.Sb.Length
    Write-BoardSerialLine -Session $Session -Text $Text
    $ok = Read-BoardSerialUntil -Session $Session -Pattern '#\s*$' -MaxMs $WaitMs -From $from
    if (-not $ok -and $WarnOnTimeout) {
        Write-Host ("  (no prompt within {0} ms after: {1})" -f $WaitMs, $Text)
    }
    Read-BoardSerial -Session $Session -Ms $PromptPollMs
    return $ok
}

function Close-BoardSerialSession {
    param($Session)
    if ($Session.Sp -and $Session.Sp.IsOpen) { $Session.Sp.Close() }
}

# Strip ANSI escape sequences (the board's shell colours the prompt and emits
# OSC 3008 "shell integration" records, e.g. ESC ]3008;... BEL).
function ConvertFrom-Ansi {
    param([string]$Text)
    $t = $Text -replace '\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)', ''   # OSC ... BEL / ST
    $t = $t -replace '\x1b\[[0-9;?]*[a-zA-Z]', ''                  # CSI
    $t = $t -replace '\x1b[()][A-Za-z0-9]', ''                     # charset designation
    return ($t -replace '\x1b', '')
}

# Last N non-empty lines of the session, ANSI stripped.
function Get-BoardSerialTail {
    param($Session, [int]$Lines = 40)
    $t = ConvertFrom-Ansi $Session.Sb.ToString()
    return (($t -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last $Lines)
}
