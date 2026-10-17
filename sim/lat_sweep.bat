@echo off
rem ============================================================
rem lat_sweep.bat - sweep the AXI read latency (LAT=1..32)
rem   Caches/logs go to Desktop\Cache\lat_sweep.
rem ============================================================
setlocal
set XV=D:\AMDDesignTools\2026.1\Vivado\bin
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
    "%SRC%\sim\tb_gc_top.v" > lat_xvlog.log 2>&1
if errorlevel 1 (
  echo COMPILE FAILED - see lat_xvlog.log
  exit /b 1
)

for %%L in (1 2 4 8 16 24 32) do (
  call "%XV%\xelab.bat" tb_gc_top -s tbL%%L --debug typical --mt 20 -generic_top "LAT=%%L" > lat_xelab_%%L.log 2>&1
  if errorlevel 1 (
    echo ELAB FAILED at LAT=%%L
  ) else (
    call "%XV%\xsim.bat" tbL%%L -R > lat_L%%L.log 2>&1
    echo done LAT=%%L
  )
)
echo === SWEEP DONE ===
echo cache dir: %CACHE%
