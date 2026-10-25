@echo off
chcp 65001 >nul
rem ============================================================
rem run_regs_aww_tb.bat - directed test for the AW/W pairing contract
rem   of the AXI-Lite register block (tb_regs_aww).
rem
rem   Green on the current RTL: P1 matched pairs, P2 duplicate-store tag
rem   rule, P3 no W beat without a pending AW.  P4 prints the pins-level
rem   limits that AGENTS #20 records (INFO, not a verdict).
rem
rem   Cache/logs go to ..\..\Cache\regs_aww_tb.
rem   Set VIVADO_BIN to the folder holding vivado.bat, or have it on PATH.
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
set CACHE=%~dp0..\..\Cache\regs_aww_tb

if not exist "%XV%\xvlog.bat" (
    echo ERROR: xvlog.bat not found at %XV%
    exit /b 1
)
if not exist "%CACHE%" mkdir "%CACHE%"
cd /d "%CACHE%"

echo === xvlog ===
call "%XV%\xvlog.bat" "%SRC%\rtl\gc_regs.v" "%SRC%\sim\tb_regs_aww.v"
if errorlevel 1 goto :err

echo === xelab ===
call "%XV%\xelab.bat" tb_regs_aww -s regs_aww_tb --mt 8
if errorlevel 1 goto :err

echo === xsim ===
call "%XV%\xsim.bat" regs_aww_tb -R > regs_aww_tb.log 2>&1
set "XRC=%errorlevel%"
type regs_aww_tb.log
if not "%XRC%"=="0" goto :err

findstr /C:"[AW-W][FAIL]" regs_aww_tb.log >nul
if not errorlevel 1 goto :tbfail

rem The banner is the verdict; a truncated log must not pass.
findstr /C:"[AW-W] ==================== PASS" regs_aww_tb.log >nul
if errorlevel 1 goto :nobanner

echo === REGS AWW TB DONE ===
for %%I in ("%CACHE%") do echo cache dir: Cache\%%~nxI
exit /b 0

:nobanner
echo === REGS AWW TB DID NOT REACH ITS PASS BANNER (see %CACHE%\regs_aww_tb.log) ===
exit /b 1

:tbfail
echo === REGS AWW TB REPORTED FAILURES (see %CACHE%\regs_aww_tb.log) ===
exit /b 1

:err
echo === BUILD/SIM FAILED ===
exit /b 1