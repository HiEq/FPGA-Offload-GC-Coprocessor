@echo off
rem ============================================================
rem run_axi_tb.bat - directed unit test for gc_axi_read (#6 outstanding cap)
rem ============================================================
setlocal
set XV=D:\AMDDesignTools\2026.1\Vivado\bin
cd /d "%~dp0"

if not exist "%XV%\xvlog.bat" (
    echo ERROR: xvlog.bat not found at %XV%
    exit /b 1
)

echo === xvlog ===
call "%XV%\xvlog.bat" ..\rtl\gc_axi_read.v tb_axi_read.v
if errorlevel 1 goto :err

echo === xelab ===
call "%XV%\xelab.bat" tb_axi_read -s axi_tb --mt 20
if errorlevel 1 goto :err

echo === xsim ===
call "%XV%\xsim.bat" axi_tb -R
if errorlevel 1 goto :err

echo === AXI TB DONE ===
exit /b 0

:err
echo === BUILD/SIM FAILED ===
exit /b 1
