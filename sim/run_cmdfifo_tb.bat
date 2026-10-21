@echo off
chcp 65001 >nul
rem ============================================================
rem run_cmdfifo_tb.bat - directed test for the command-FIFO half of
rem   the run_start/abort flush (tb_cmdfifo_flush).
rem
rem   Unfixed RTL: [CMDFIFO][FAIL] stale ARADDR=0x30000008 (or 0x10/0x18)
rem   Fixed RTL:   [CMDFIFO] ==================== PASS
rem
rem   Cache/logs go to ..\..\Cache\cmdfifo_tb.
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
set CACHE=%~dp0..\..\Cache\cmdfifo_tb

if not exist "%XV%\xvlog.bat" (
    echo ERROR: xvlog.bat not found at %XV%
    exit /b 1
)
if not exist "%CACHE%" mkdir "%CACHE%"
cd /d "%CACHE%"

echo === xvlog ===
call "%XV%\xvlog.bat" -sv ^
    "%SRC%\rtl\gc_axi_read.v" ^
    "%SRC%\sim\tb_cmdfifo_flush.v"
if errorlevel 1 goto :err

echo === xelab ===
call "%XV%\xelab.bat" tb_cmdfifo_flush -s cmdfifo_tb --mt 8
if errorlevel 1 goto :err

echo === xsim ===
call "%XV%\xsim.bat" cmdfifo_tb -R > cmdfifo_tb.log 2>&1
set "XRC=%errorlevel%"
type cmdfifo_tb.log
if not "%XRC%"=="0" goto :err

findstr /C:"[CMDFIFO][FAIL]" cmdfifo_tb.log >nul
if not errorlevel 1 goto :tbfail

rem The banner is the verdict; a truncated log must not pass.
findstr /C:"[CMDFIFO] ==================== PASS" cmdfifo_tb.log >nul
if errorlevel 1 goto :nobanner

echo === CMDFIFO TB DONE ===
echo cache dir: %CACHE%
exit /b 0

:nobanner
echo === CMDFIFO TB DID NOT REACH ITS PASS BANNER (see %CACHE%\cmdfifo_tb.log) ===
exit /b 1

:tbfail
echo === CMDFIFO TB REPORTED FAILURES (see %CACHE%\cmdfifo_tb.log) ===
exit /b 1

:err
echo === BUILD/SIM FAILED ===
exit /b 1
