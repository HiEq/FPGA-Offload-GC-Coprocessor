param(
    [Parameter(Mandatory=$true)][string]$Cmd,
    [int]$WaitMs = 8000,
    [string]$Port = "auto"
)
$ErrorActionPreference = 'Stop'

# Port auto-detection + shared plumbing: see serial-session.ps1
# (serial-port.ps1 is dot-sourced from there).
. (Join-Path $PSScriptRoot 'serial-session.ps1')

$s = New-BoardSerialSession -Port $Port
Read-BoardSerial -Session $s -Ms 300
$s.Sp.Write("`n")
Read-BoardSerial -Session $s -Ms 400

# The offset matters: without it an old prompt already sitting in the buffer ends
# the wait before this command has produced anything. serial_run_gc.ps1 had been
# fixed for that; this script still had the bug.
$from = $s.Sb.Length
Write-BoardSerialLine -Session $s -Text $Cmd -SettleMs 0
[void](Read-BoardSerialUntil -Session $s -Pattern '#\s*$' -MaxMs $WaitMs -From $from)
Read-BoardSerial -Session $s -Ms 300
Close-BoardSerialSession -Session $s

Get-BoardSerialTail -Session $s -Lines 40 | ForEach-Object { "  | " + $_ }
