# Unit test for tools/serial-session.ps1 - no board and no COM port needed.
#
#   powershell -ExecutionPolicy Bypass -File tools\tests\test-serial-session.ps1
#
# Covers:
#   * ANSI stripping
#   * tail extraction (last N non-empty lines)
#   * boundary: empty buffer
#   * the $From offset semantics - NEGATIVE CONTROL: a stale prompt already in
#     the buffer must NOT satisfy a wait that starts after it.

$ErrorActionPreference = 'Stop'
$tools = Split-Path -Parent $PSScriptRoot
. (Join-Path $tools 'serial-session.ps1')

$script:fail = 0
function Check([string]$name, [bool]$cond) {
    if ($cond) { Write-Host ("PASS " + $name) }
    else       { Write-Host ("FAIL " + $name); $script:fail++ }
}

# Buffer-only session (Sp = $null): the helpers must work without hardware.
function New-FakeSession([string]$initial) {
    $s = @{
        Port = 'COM0'
        Baud = 115200
        Sp   = $null
        Sb   = (New-Object System.Text.StringBuilder)
    }
    if ($initial) { [void]$s.Sb.Append($initial) }
    return $s
}

# 1) ANSI strip
$esc = [char]27
Check "ansi strip" ((ConvertFrom-Ansi ($esc + "[1;31mred" + $esc + "[0m")) -eq "red")
Check "osc strip" ((ConvertFrom-Ansi ($esc + "]3008;start=abc;cwd=/root" + [char]7 + "ls")) -eq "ls")

# 2) tail = last N non-empty lines
$s = New-FakeSession ("a`r`n`r`nb`r`nc`r`n")
Check "tail keeps last 2" (((Get-BoardSerialTail -Session $s -Lines 2) -join '|') -eq 'b|c')

# 3) NEGATIVE CONTROL: stale prompt before $From must not match
$s = New-FakeSession ("banner`r`nroot@board:~# `r`n")
$from = $s.Sb.Length
[void]$s.Sb.Append("still running, no prompt yet`r`n")
Check "stale prompt ignored (negative control)" (-not (Read-BoardSerialUntil -Session $s -Pattern '#\s*$' -MaxMs 10 -From $from))

# 4) happy path: a fresh prompt after $From does match
[void]$s.Sb.Append("root@board:~# ")
Check "fresh prompt detected" (Read-BoardSerialUntil -Session $s -Pattern '#\s*$' -MaxMs 10 -From $from)

# 5) boundary: empty buffer does not match
$s2 = New-FakeSession ""
Check "empty buffer does not match" (-not (Read-BoardSerialUntil -Session $s2 -Pattern '#\s*$' -MaxMs 10 -From 0))

if ($script:fail -eq 0) {
    Write-Host "SERIAL_SESSION_TEST PASS"
    exit 0
}
Write-Host ("SERIAL_SESSION_TEST FAIL (" + $script:fail + ")")
exit 1
