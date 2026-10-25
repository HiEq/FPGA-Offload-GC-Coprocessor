# reproduce_all.ps1 - run every host-side check in one command.
#
#   powershell -ExecutionPolicy Bypass -File tools\reproduce_all.ps1
#
# Steps that need the board are printed, not executed:
#   test_main / run_gc.sh / three_way.py / irq test (see README "板上测试命令速查").
param(
    [string]$VivadoBin = $env:VIVADO_BIN
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fail = 0

function Step($name, $block) {
    Write-Host "=== $name ==="
    & $block
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAIL: $name" -ForegroundColor Red
        $script:fail = 1
    }
}

if ($VivadoBin) { $env:VIVADO_BIN = $VivadoBin }

Step 'binary manifest' { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\make_manifest.ps1') -Check }

Step 'PowerShell unit test' { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\tests\test-serial-session.ps1') }

Step 'sim: tb_gc_top' { & cmd /c (Join-Path $root 'sim\run_sim.bat') }

Step 'sim: tb_axi_read' { & cmd /c (Join-Path $root 'sim\run_axi_tb.bat') }

Step 'sim: tb_runstart_race' { & cmd /c (Join-Path $root 'sim\run_race_tb.bat') }

Step 'sim: tb_cmdfifo_flush' { & cmd /c (Join-Path $root 'sim\run_cmdfifo_tb.bat') }

Step 'sim: tb_regs_aww' { & cmd /c (Join-Path $root 'sim\run_regs_aww_tb.bat') }

Step 'sim: hand-over TBs' { & cmd /c (Join-Path $root 'sim\run_port_tb.bat') }

Write-Host ''
Write-Host 'Board steps (manual):'
Write-Host '  D=$(for d in /run/media/USERDATA-mmcblk0p2 /mnt/userdata; do [ -d "$d/tests" ] && echo $d && break; done)'
Write-Host '  sh $D/run_gc.sh 4096 8 2'
Write-Host '  $D/bin/test_main'
Write-Host '  cd $D && python3 tests/three_way.py'
Write-Host '  D=$D sh $D/tests/irq_drv_test.sh   (PL must be freshly configured)'
Write-Host ''
if ($fail) { Write-Host 'RESULT: FAIL'; exit 1 }
Write-Host 'RESULT: PASS (host-side checks only)'
