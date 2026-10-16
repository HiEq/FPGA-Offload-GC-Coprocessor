@echo off
rem ============================================================
rem run_sim.bat — 用 Vivado xsim 跑 tb_gc_top
rem   验证 gc_axi_read(读命令队列) + gc_mark_engine(并发读) 的功能
rem ============================================================
setlocal
set XV=D:\AMDDesignTools\2026.1\Vivado\bin
cd /d "%~dp0"

if not exist "%XV%\xvlog.bat" (
    echo ERROR: xvlog.bat not found at %XV%
    exit /b 1
)

echo === xvlog ===
call "%XV%\xvlog.bat" ^
    ..\rtl\gc_top.v ^
    ..\rtl\gc_mark_engine.v ^
    ..\rtl\gc_axi_read.v ^
    ..\rtl\gc_bitmap.v ^
    ..\rtl\gc_queue.v ^
    ..\rtl\gc_regs.v ^
    tb_gc_top.v
if errorlevel 1 goto :err

echo === xelab ===
call "%XV%\xelab.bat" tb_gc_top -s tb_sim --debug typical
if errorlevel 1 goto :err

echo === xsim ===
call "%XV%\xsim.bat" tb_sim -R
if errorlevel 1 goto :err

echo === SIM DONE ===
exit /b 0

:err
echo === BUILD/SIM FAILED ===
exit /b 1
