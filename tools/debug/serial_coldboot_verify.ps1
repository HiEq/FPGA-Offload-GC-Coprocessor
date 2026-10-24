# ============================================================
# serial_coldboot_verify.ps1 - log in after a cold boot and check the environment
#
#   powershell -ExecutionPolicy Bypass -File tools\debug\serial_coldboot_verify.ps1
#
# Logs in as root (empty password, idempotent: skips if already logged in) and
# captures: kernel/env, the BOOT partition's BOOT.BIN sha256+md5 (must match the
# repacked image), mounts, the FOGCCC device-tree no-map node, FPGA manager
# state and the C test_main result.
#
# Completion sentinels are printf-split ("printf 'D''1=%s\n' $?") so the echoed
# command can never satisfy the wait pattern (see tools/serial_phase2.ps1).
# ============================================================
param(
    [string]$Port = 'auto',
    [string]$DataDir = '/run/media/USERDATA-mmcblk0p2'
)
$ErrorActionPreference = 'Continue'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'serial-session.ps1')

$s = New-BoardSerialSession -Port $Port
Read-BoardSerial -Session $s -Ms 1000
$s.Sp.Write("`r")
Read-BoardSerial -Session $s -Ms 800

if ($s.Sb.ToString() -notmatch 'root@[^\r\n]*[#$]') {
    'state: not logged in'
    if ($s.Sb.ToString() -notmatch 'login:') {
        [void](Read-BoardSerialUntil -Session $s -Pattern 'login:' -MaxMs 6000 -From $s.Sb.Length)
    }
    $from = $s.Sb.Length
    Write-BoardSerialLine -Session $s -Text 'root' -SettleMs 0
    [void](Read-BoardSerialUntil -Session $s -Pattern 'root@[^\r\n]*[#$]' -MaxMs 15000 -From $from)
    Read-BoardSerial -Session $s -Ms 600
} else {
    'state: already logged in'
}
Read-BoardSerial -Session $s -Ms 300

function Run-Cmd([string]$cmd, [string]$pat, [int]$maxMs) {
    $from = $s.Sb.Length
    Write-BoardSerialLine -Session $s -Text $cmd -SettleMs 0
    [void](Read-BoardSerialUntil -Session $s -Pattern $pat -MaxMs $maxMs -From $from)
    Read-BoardSerial -Session $s -Ms 400
    $out = $s.Sb.ToString($from, $s.Sb.Length - $from)
    return (ConvertFrom-Ansi $out)
}

$cmds = @(
    @("uname -a; uptime; cat /proc/cmdline; printf 'D''1=%s\n' `$?", 'D1='),
    @("f=0; for d in /boot /run/media/BOOT-mmcblk0p1 /run/media/* `$DataDir /mnt; do if [ -e `$d/BOOT.BIN ]; then echo BOOTBIN_AT=`$d; sha256sum `$d/BOOT.BIN; md5sum `$d/BOOT.BIN; f=1; fi; done; echo BOOTBIN_SEEN=`$f; test `$f = 1; printf 'D''2=%s\n' `$?", 'D2='),
    @("mount | grep -E 'mmcblk0|boot|USERDATA'; ls /run/media/; printf 'D''3=%s\n' `$?", 'D3='),
    @("ls -la $DataDir/ | head -16; printf 'D''4=%s\n' `$?", 'D4='),
    @("test -e /proc/device-tree/reserved-memory/pl_graph@1e000000/no-map && echo PL_GRAPH_NOMAP_OK || echo PL_GRAPH_NOMAP_MISSING; cat /sys/class/fpga_manager/fpga0/state 2>/dev/null; printf 'D''5=%s\n' `$?", 'D5='),
    @("cd $DataDir && ./bin/test_main; printf 'D''6=%s\n' `$?", 'D6=')
)
foreach ($c in $cmds) {
    $r = Run-Cmd $c[0] $c[1] 60000
    $r -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | ForEach-Object { '  | ' + $_.TrimEnd() }
    ''
}
Close-BoardSerialSession -Session $s