@echo off
setlocal
set XV=D:\AMDDesignTools\2026.1\Vivado\bin
cd /d "%~dp0"

echo === compile once ===
call "%XV%\xvlog.bat" ..\rtl\gc_top.v ..\rtl\gc_mark_engine.v ..\rtl\gc_axi_read.v ..\rtl\gc_bitmap.v ..\rtl\gc_queue.v ..\rtl\gc_regs.v tb_gc_top.v > lat_xvlog.log 2>&1
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
