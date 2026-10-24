@echo off
chcp 65001 >nul
rem ============================================================
rem run_sim.bat - run Vivado xsim on tb_gc_top
rem   Verifies gc_axi_read (read command queue) + gc_mark_engine.
rem   Simulation caches and logs go to Desktop\Cache\sim.
rem
rem   Exit code is evidence: xsim returns 0 even when the TB prints
rem   failures ($finish, not $fatal), so the log is grepped too.
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
    "%SRC%\rtl\gc_freelist.v" ^
    "%SRC%\rtl\gc_dirty_fifo.v" ^
    "%SRC%\rtl\gc_regs.v" ^
    "%SRC%\sim\axi_proto_check.v" ^
    "%SRC%\sim\tb_gc_top.v"
if errorlevel 1 goto :err

echo === xelab ===
call "%XV%\xelab.bat" tb_gc_top -s tb_sim --debug typical --mt 20
if errorlevel 1 goto :err

echo === xsim ===
call "%XV%\xsim.bat" tb_sim -R > xsim_tb.log 2>&1
set "XRC=%errorlevel%"
type xsim_tb.log
if not "%XRC%"=="0" goto :err

rem xsim exits 0 when the TB reports failures, so grep the transcript.
findstr /C:"[TB][FAIL]" /C:"[AXI][FAIL]" xsim_tb.log >nul
if not errorlevel 1 goto :tbfail

rem A truncated/empty log must not pass either: the TB prints this banner only
rem after every check has run, so its absence means the verdict never happened.
findstr /C:"[TB] ==================== PASS" xsim_tb.log >nul
if errorlevel 1 goto :nopass

echo === SIM DONE ===
echo cache dir: %CACHE%
exit /b 0

:nopass
echo === SIM DID NOT REACH ITS PASS BANNER (see %CACHE%\xsim_tb.log) ===
exit /b 1

:tbfail
echo === SIM REPORTED FAILURES (see %CACHE%\xsim_tb.log) ===
exit /b 1

:err
echo === BUILD/SIM FAILED ===
exit /b 1
