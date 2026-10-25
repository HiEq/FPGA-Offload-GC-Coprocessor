@echo off
chcp 65001 >nul
rem ============================================================
rem run_race_tb.bat - directed test for the run_start/abort
rem   same-cycle stale-R hole (tb_runstart_race).
rem
rem   Unfixed RTL: [RACE][FAIL] stale beat survived the flush
rem   Fixed RTL:   [RACE] ==================== PASS
rem
rem   Cache/logs go to ..\..\Cache\race_tb.
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
set CACHE=%~dp0..\..\Cache\race_tb

if not exist "%XV%\xvlog.bat" (
    echo ERROR: xvlog.bat not found at %XV%
    exit /b 1
)
if not exist "%CACHE%" mkdir "%CACHE%"
cd /d "%CACHE%"

echo === xvlog ===
call "%XV%\xvlog.bat" -sv ^
    "%SRC%\rtl\gc_axi_read.v" ^
    "%SRC%\sim\axi_proto_check.v" ^
    "%SRC%\sim\tb_runstart_race.v"
if errorlevel 1 goto :err

echo === xelab ===
call "%XV%\xelab.bat" tb_runstart_race -s race_tb --mt 8
if errorlevel 1 goto :err

echo === xsim ===
call "%XV%\xsim.bat" race_tb -R > race_tb.log 2>&1
set "XRC=%errorlevel%"
type race_tb.log
if not "%XRC%"=="0" goto :err

findstr /C:"[RACE][FAIL]" race_tb.log >nul
if not errorlevel 1 goto :tbfail

rem The banner is the verdict; a truncated log must not pass.
findstr /C:"[RACE] ==================== PASS" race_tb.log >nul
if errorlevel 1 goto :nobanner

echo === RACE TB DONE ===
for %%I in ("%CACHE%") do echo cache dir: Cache\%%~nxI
exit /b 0

:nobanner
echo === RACE TB DID NOT REACH ITS PASS BANNER (see %CACHE%\race_tb.log) ===
exit /b 1

:tbfail
echo === RACE TB REPORTED FAILURES (see %CACHE%\race_tb.log) ===
exit /b 1

:err
echo === BUILD/SIM FAILED ===
exit /b 1
