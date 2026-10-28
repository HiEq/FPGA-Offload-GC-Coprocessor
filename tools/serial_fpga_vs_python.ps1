param([string]$Port = "auto")

$ErrorActionPreference = 'Stop'

# Port auto-detection + shared plumbing live in serial-session.ps1, which in
# turn dot-sources serial-port.ps1.
. (Join-Path $PSScriptRoot 'serial-session.ps1')

# logs directory
$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outFile = "$PSScriptRoot\logs\board_verify_$stamp.log"

$s = New-BoardSerialSession -Port $Port
Write-Host ("opened {0} @ {1}" -f $s.Port, $s.Baud)

# Thin wrappers so the body below reads like the original script.
function SendLine([string]$text) {
    Write-Host ("> " + $text)
    Write-BoardSerialLine -Session $s -Text $text
}
function Cmd([string]$text, [int]$waitMs) {
    [void](Invoke-BoardSerialCommand -Session $s -Text $text -WaitMs $waitMs -Echo -WarnOnTimeout)
}

# ================= 1) login =================
Write-Host "--- 1) login ---"
Read-BoardSerial -Session $s -Ms 500
$s.Sp.Write("`r")
Read-BoardSerial -Session $s -Ms 1200

$loggedIn = $false
# The shipped image sets CONFIG_imagefeature-empty-root-password=y, but an image
# rebuilt without it would ask for a password; try empty first, then "root".
$passwords = @('', 'root', 'root')
for ($try = 1; $try -le 3; $try++) {
    $tail = $s.Sb.ToString()
    if ($tail.Length -gt 400) { $tail = $tail.Substring($tail.Length - 400) }
    if ($tail -match '#\s*$') { $loggedIn = $true; break }
    Write-Host ("  attempt " + $try + ": sending user root")
    $s.Sp.Write("root`n")
    Read-BoardSerial -Session $s -Ms 2500
    $tail = $s.Sb.ToString()
    if ($tail.Length -gt 400) { $tail = $tail.Substring($tail.Length - 400) }
    if ($tail -match 'Password:') {
        $pw = $passwords[$try - 1]
        if ($pw) { Write-Host "  password prompt -> sending 'root'" }
        else     { Write-Host "  password prompt -> sending empty password" }
        $s.Sp.Write($pw + "`n")
        Read-BoardSerial -Session $s -Ms 2500
    }
    if (Read-BoardSerialUntil -Session $s -Pattern '#\s*$' -MaxMs 15000) { $loggedIn = $true; break }
}
Write-Host ("  logged in = " + $loggedIn)
if (-not $loggedIn) {
    Write-Host "  LOGIN FAILED, tail:"
    Get-BoardSerialTail -Session $s -Lines 15 | ForEach-Object { "  | " + $_ }
    Close-BoardSerialSession -Session $s
    [System.IO.File]::WriteAllText($outFile, $s.Sb.ToString())
    exit 2
}
Read-BoardSerial -Session $s -Ms 400

# ================= 1b) host time sync =================
# The board has no RTC and no network, so its clock falls back to 2018-03-09 on
# every power-up. Push the host's UTC time in, so fpga_vs_python.sh writes its
# fpga_vs_python_run_*.log files under a real date.
Write-Host "--- 1b) host time sync ---"
$hostUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
Cmd "date -s '$hostUtc'" 8000
Cmd "date" 8000

# ================= 2) mount + check =================
Write-Host "--- 2) mount + verify files ---"
Cmd "mkdir -p /mnt/userdata" 8000
Cmd "mount -t vfat /dev/mmcblk0p2 /mnt/userdata" 8000
Cmd "df -h /mnt/userdata | tail -2" 8000
Cmd "md5sum /mnt/userdata/fpga_vs_python.py" 15000
Cmd "ls -l /mnt/boot/BOOT.BIN 2>/dev/null || ls -l /run/media/*/BOOT.BIN 2>/dev/null || echo no-boot-mount" 10000
Cmd "cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || echo no-fpga-manager" 8000

# ================= 3) fpga_vs_python.sh =================
Write-Host "--- 3) fpga_vs_python.sh ---"
# Only output produced from here on may satisfy the verdict pattern: the buffer
# still holds the whole session, including earlier 'FAILED' lines.
$from = $s.Sb.Length
# `$? must reach the board literally: in a double-quoted string PowerShell
# expands it to True/False.
SendLine "sh /mnt/userdata/fpga_vs_python.sh; echo RUN_RC=`$?"
$done = Read-BoardSerialUntil -Session $s -Pattern 'PASSED \(all invariants\)|FAILED|Traceback|no trials completed' -MaxMs 420000 -From $from
Write-Host ("  finished = " + $done)
# Let the shell print the exit-code line that follows the summary.
Read-BoardSerial -Session $s -Ms 3000
$new   = $s.Sb.ToString($from, $s.Sb.Length - $from)
$lines = ($new -split "`r?`n")
$ml    = $lines | Where-Object { $_ -match 'PASSED \(all invariants\)|FAILED|Traceback|no trials completed' } | Select-Object -First 1
if ($ml) { Write-Host ("  verdict line: " + ((ConvertFrom-Ansi $ml).Trim())) }
$rcLine = $lines | Where-Object { $_ -match 'RUN_RC=\d+' } | Select-Object -Last 1

Close-BoardSerialSession -Session $s
[System.IO.File]::WriteAllText($outFile, $s.Sb.ToString())
Write-Host ("transcript: " + $outFile)

Write-Host "--- tail ---"
Get-BoardSerialTail -Session $s -Lines 30 | ForEach-Object { "  | " + $_ }

# Exit code is evidence: before this, the one-click acceptance script returned 0
# even when the board run failed, and only a human reading the log could tell.
if (-not $done) {
    Write-Host "RESULT: FAIL (no verdict line within the timeout)"
    exit 1
}
if ($ml -match 'FAILED|Traceback|no trials completed') {
    Write-Host ("RESULT: FAIL (" + (ConvertFrom-Ansi $ml).Trim() + ")")
    exit 1
}
# "PASSED (all invariants): 7/8" is a failure; only n == n counts.
if ($ml -match 'PASSED \(all invariants\):\s*(\d+)/(\d+)') {
    if ($Matches[1] -ne $Matches[2]) {
        Write-Host ("RESULT: FAIL (partial: " + $Matches[1] + "/" + $Matches[2] + ")")
        exit 1
    }
}
# The board's own exit code is the last word, and it must actually be present:
# a truncated transcript that never shows RUN_RC is not a pass.
if (-not $rcLine) {
    Write-Host "RESULT: FAIL (no RUN_RC line; transcript truncated?)"
    exit 1
}
if ($rcLine -match 'RUN_RC=(\d+)' -and $Matches[1] -ne '0') {
    Write-Host ("RESULT: FAIL (fpga_vs_python.sh exit " + $Matches[1] + ")")
    exit 1
}
Write-Host "RESULT: PASS"
exit 0
