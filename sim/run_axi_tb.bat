@echo off
chcp 65001 >nul
rem ============================================================
rem run_axi_tb.bat - directed unit test for gc_axi_read (outstanding cap)
rem   Caches/logs go to Desktop\Cache\axi_tb.
rem
rem   Exit code is evidence: xsim returns 0 even on TB failures, so the log
rem   is grepped for [AXITB][FAIL] / [AXI][FAIL] / [TB][FAIL], and the TB's own
rem   PASS banner must be present (a missing banner is a failure too).
rem   Set VIVADO_BIN to the folder holding vivado.bat, or have vivado.bat on PATH.
rem ============================================================
setlocal
set "XV="
if not "%VIVADO_BIN%"=="" set "XV=%VIVADO_BIN%"
if not defined XV for /f "delims=" %%i in ('where vivado.bat 2^>nul') do set "XV=%%~dpi"
if not defined XV (
    echo ERROR: Vivado not found. Set VIVADO_BIN to the folder containing vivado.bat.
    exit /b 1
)
set SRC=%~dp0..
set CACHE=%~dp0..\..\Cache\axi_tb

if not exist "%XV%\xvlog.bat" (
    echo ERROR: xvlog.bat not found at %XV%
    exit /b 1
)
if not exist "%CACHE%" mkdir "%CACHE%"
cd /d "%CACHE%"

echo === xvlog ===
call "%XV%\xvlog.bat" "%SRC%\rtl\gc_axi_read.v" "%SRC%\sim\axi_proto_check.v" "%SRC%\sim\tb_axi_read.v"
if errorlevel 1 goto :err

echo === xelab ===
call "%XV%\xelab.bat" tb_axi_read -s axi_tb --mt 20
if errorlevel 1 goto :err

echo === xsim ===
call "%XV%\xsim.bat" axi_tb -R > axi_tb.log 2>&1
set "XRC=%errorlevel%"
type axi_tb.log
if not "%XRC%"=="0" goto :err

findstr /C:"[AXITB][FAIL]" /C:"[AXI][FAIL]" /C:"[TB][FAIL]" axi_tb.log >nul
if not errorlevel 1 goto :tbfail

rem The TB prints its own banner; without it the run did not reach the verdict.
findstr /C:"[AXITB] ==================== PASS" axi_tb.log >nul
if errorlevel 1 goto :nobanner

echo === AXI TB DONE ===
for %%I in ("%CACHE%") do echo cache dir: Cache\%%~nxI
exit /b 0

:nobanner
echo === AXI TB DID NOT REACH ITS PASS BANNER (see %CACHE%\axi_tb.log) ===
exit /b 1

:tbfail
echo === AXI TB REPORTED FAILURES (see %CACHE%\axi_tb.log) ===
exit /b 1

:err
echo === BUILD/SIM FAILED ===
exit /b 1
