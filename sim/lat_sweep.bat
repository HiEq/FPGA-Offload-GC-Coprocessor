@echo off
rem ============================================================
rem lat_sweep.bat - sweep the AXI read latency (LAT=1..32)
rem   Caches/logs go to Desktop\Cache\lat_sweep.
rem
rem   Each LAT run is grepped for [TB][FAIL] / [AXI][FAIL]; one bad LAT makes
rem   the whole sweep exit 1 (xsim itself exits 0 on TB failures).
rem   Set VIVADO_BIN to the folder holding vivado.bat, or have vivado.bat on PATH.
rem ============================================================
setlocal enabledelayedexpansion
set "XV="
if not "%VIVADO_BIN%"=="" set "XV=%VIVADO_BIN%"
if not defined XV for /f "delims=" %%i in ('where vivado.bat 2^>nul') do set "XV=%%~dpi"
if not defined XV (
    echo ERROR: Vivado not found. Set VIVADO_BIN to the folder containing vivado.bat.
    exit /b 1
)
set SRC=%~dp0..
set CACHE=%~dp0..\..\Cache\lat_sweep

if not exist "%XV%\xvlog.bat" (
    echo ERROR: xvlog.bat not found at %XV%
    exit /b 1
)
if not exist "%CACHE%" mkdir "%CACHE%"
cd /d "%CACHE%"

echo === compile once ===
call "%XV%\xvlog.bat" ^
    "%SRC%\rtl\gc_top.v" ^
    "%SRC%\rtl\gc_mark_engine.v" ^
    "%SRC%\rtl\gc_axi_read.v" ^
    "%SRC%\rtl\gc_bitmap.v" ^
    "%SRC%\rtl\gc_queue.v" ^
    "%SRC%\rtl\gc_regs.v" ^
    "%SRC%\sim\axi_proto_check.v" ^
    "%SRC%\sim\tb_gc_top.v" > lat_xvlog.log 2>&1
if errorlevel 1 (
  echo COMPILE FAILED - see lat_xvlog.log
  exit /b 1
)

set "FAILED="
for %%L in (1 2 4 8 16 24 32) do (
  call "%XV%\xelab.bat" tb_gc_top -s tbL%%L --debug typical --mt 20 -generic_top "LAT=%%L" > lat_xelab_%%L.log 2>&1
  if errorlevel 1 (
    echo ELAB FAILED at LAT=%%L
    set "FAILED=1"
  ) else (
    call "%XV%\xsim.bat" tbL%%L -R > lat_L%%L.log 2>&1
    findstr /C:"[TB][FAIL]" /C:"[AXI][FAIL]" lat_L%%L.log >nul
    if not errorlevel 1 (
      echo SIM FAILED at LAT=%%L - see lat_L%%L.log
      set "FAILED=1"
    ) else (
      echo done LAT=%%L
    )
  )
)
echo === SWEEP DONE ===
echo cache dir: %CACHE%
if defined FAILED (
  echo === SWEEP HAD FAILURES ===
  exit /b 1
)
exit /b 0
