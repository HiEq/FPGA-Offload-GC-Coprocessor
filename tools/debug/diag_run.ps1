param(
    [Parameter(Mandatory=$true)][string]$Cmd,
    [string]$Until = 'DIAG_DONE',
    [int]$MaxMs = 180000,
    [string]$Port = 'auto',
    [string]$OutFile = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'serial-session.ps1')

$s = New-BoardSerialSession -Port $Port

# Boot-window rule (learned the hard way): ANY byte sent during U-Boot's bootdelay
# aborts autoboot and drops the board into `Zynq>`.  So probe by READING first and
# only write once a shell (or a login prompt) is known to be there.
[void](Read-BoardSerial -Session $s -Ms 1200)
if ($s.Sb.ToString() -match 'Zynq>') {
    # already at the U-Boot prompt: recover instead of feeding it commands
    Write-BoardSerialLine -Session $s -Text 'boot' -SettleMs 1000
    [void](Read-BoardSerialUntil -Session $s -Pattern 'login:' -MaxMs 240000)
    Write-BoardSerialLine -Session $s -Text 'root' -SettleMs 2500
    [void](Read-BoardSerialUntil -Session $s -Pattern 'root@' -MaxMs 60000)
} elseif ($s.Sb.ToString() -notmatch 'root@') {
    [void](Read-BoardSerialUntil -Session $s -Pattern 'login:|root@' -MaxMs 20000)
    if ($s.Sb.ToString() -match 'login:') {
        Write-BoardSerialLine -Session $s -Text 'root' -SettleMs 2500
        [void](Read-BoardSerialUntil -Session $s -Pattern 'root@' -MaxMs 60000)
    }
}
$s.Sp.Write("`r")
Read-BoardSerial -Session $s -Ms 800

$from = $s.Sb.Length
Write-BoardSerialLine -Session $s -Text $Cmd -SettleMs 0
[void](Read-BoardSerialUntil -Session $s -Pattern $Until -MaxMs $MaxMs -From $from)
Read-BoardSerial -Session $s -Ms 500
$out = $s.Sb.ToString($from, $s.Sb.Length - $from)
Close-BoardSerialSession -Session $s

$clean = ConvertFrom-Ansi $out
if ($OutFile -ne '') { [System.IO.File]::WriteAllText($OutFile, $clean) }
$clean -split "`r?`n" | Where-Object { $_ -ne '' } | ForEach-Object { $_ }