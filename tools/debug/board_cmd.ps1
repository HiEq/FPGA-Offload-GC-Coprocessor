param(
    [Parameter(Mandatory=$true)][string]$Cmd,
    [string]$Until = 'DIAG_DONE',
    [int]$MaxMs = 600000,
    [string]$Port = 'auto',
    [string]$OutFile = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'serial-session.ps1')
$s = New-BoardSerialSession -Port $Port

function Read-Some([int]$ms) { [void](Read-BoardSerial -Session $s -Ms $ms) }
function Seen([string]$p) { $s.Sb.ToString() -match $p }

# --- reach a shell without ever writing into the boot window -----------------
$deadline = (Get-Date).AddSeconds(90)
$sentUser = $false
$nudged = $false
while ((Get-Date) -lt $deadline) {
    Read-Some 1000
    # A getty that printed its prompt before we attached stays silent.  Only after
    # two seconds of silence (a booting board always talks) do we send one CR to
    # re-print the prompt -- never during the boot window.
    if (-not $nudged -and -not $sentUser -and -not (Seen 'Zynq>') -and
        $s.Sb.Length -eq 0 -and -not (Seen 'login:|root@')) {
        $s.Sp.Write("`r")
        $nudged = $true
    }
    if (Seen 'Zynq>') {
        Write-BoardSerialLine -Session $s -Text 'boot' -SettleMs 1000
        continue
    }
    if (Seen 'root@[^\r\n]*[#$]') { break }
    if (Seen 'Password:') {
        Write-BoardSerialLine -Session $s -Text 'root' -SettleMs 1500
        $sentUser = $true
        continue
    }
    if ((Seen 'login:') -and -not $sentUser) {
        Write-BoardSerialLine -Session $s -Text 'root' -SettleMs 1500
        $sentUser = $true
        continue
    }
}
if (-not (Seen 'root@[^\r\n]*[#$]')) {
    $s.Sb.ToString() -split "`r?`n" | Select-Object -Last 5 | ForEach-Object { 'PROBE |' + $_ }
    Close-BoardSerialSession -Session $s
    throw 'no shell prompt'
}

$s.Sp.Write("`r")
Read-Some 600

# --- run the command --------------------------------------------------------
$from = $s.Sb.Length
Write-BoardSerialLine -Session $s -Text $Cmd -SettleMs 0
[void](Read-BoardSerialUntil -Session $s -Pattern $Until -MaxMs $MaxMs -From $from)
Read-Some 600
$out = $s.Sb.ToString($from, $s.Sb.Length - $from)
$clean = ConvertFrom-Ansi $out
if ($OutFile -ne '') { [System.IO.File]::WriteAllText($OutFile, $clean) }
Close-BoardSerialSession -Session $s
$clean -split "`r?`n" | Where-Object { $_ -ne '' } | ForEach-Object { $_ }
