@echo off
rem ============================================================
rem run_axi_tb.bat - directed unit test for gc_axi_read (outstanding cap)
rem   Caches/logs go to Desktop\Cache\axi_tb.
rem ============================================================
setlocal
set XV=D:\AMDDesignTools\2026.1\Vivado\bin
set SRC=%~dp0..
set CACHE=%~dp0..\..\Cache\axi_tb

if not exist "%XV%\xvlog.bat" (
    echo ERROR: xvlog.bat not found at %XV%
    exit /b 1
)
if not exist "%CACHE%" mkdir "%CACHE%"
cd /d "%CACHE%"

echo === xvlog ===
call "%XV%\xvlog.bat" "%SRC%\rtl\gc_axi_read.v" "%SRC%\sim\tb_axi_read.v"
if errorlevel 1 goto :err

echo === xelab ===
call "%XV%\xelab.bat" tb_axi_read -s axi_tb --mt 20
if errorlevel 1 goto :err

echo === xsim ===
call "%XV%\xsim.bat" axi_tb -R
if errorlevel 1 goto :err

echo === AXI TB DONE ===
echo cache dir: %CACHE%
exit /b 0

:err
echo === BUILD/SIM FAILED ===
exit /b 1
