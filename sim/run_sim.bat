@echo off
rem ============================================================
rem run_sim.bat - run Vivado xsim on tb_gc_top
rem   Verifies gc_axi_read (read command queue) + gc_mark_engine.
rem   All simulation caches and logs go to Desktop\Cache\sim, so the
rem   project tree stays clean.
rem ============================================================
setlocal
set XV=D:\AMDDesignTools\2026.1\Vivado\bin
set SRC=%~dp0..
set CACHE=%~dp0..\..\Cache\sim

if not exist "%XV%\xvlog.bat" (
    echo ERROR: xvlog.bat not found at %XV%
    exit /b 1
)
if not exist "%CACHE%" mkdir "%CACHE%"
cd /d "%CACHE%"

echo === xvlog ===
call "%XV%\xvlog.bat" ^
    "%SRC%\rtl\gc_top.v" ^
    "%SRC%\rtl\gc_mark_engine.v" ^
    "%SRC%\rtl\gc_axi_read.v" ^
    "%SRC%\rtl\gc_bitmap.v" ^
    "%SRC%\rtl\gc_queue.v" ^
    "%SRC%\rtl\gc_regs.v" ^
    "%SRC%\sim\axi_proto_check.v" ^
    "%SRC%\sim\tb_gc_top.v"
if errorlevel 1 goto :err

echo === xelab ===
call "%XV%\xelab.bat" tb_gc_top -s tb_sim --debug typical --mt 20
if errorlevel 1 goto :err

echo === xsim ===
call "%XV%\xsim.bat" tb_sim -R
if errorlevel 1 goto :err

echo === SIM DONE ===
echo cache dir: %CACHE%
exit /b 0

:err
echo === BUILD/SIM FAILED ===
exit /b 1
