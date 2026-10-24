@echo off
chcp 65001 >nul
rem ============================================================
rem run_port_tb.bat - the three directed testbenches that guard the
rem   run_start/abort hand-over (ported from dev-hieq #43):
rem     tb_flush_data, tb_stale_ar_flush, tb_start_while_busy
rem   Each must print its PASS banner; any [FAIL] line fails the step.
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
set CACHE=%~dp0..\..\Cache\port_tb
if not exist "%CACHE%" mkdir "%CACHE%"
cd /d "%CACHE%"
set "FAILED="

echo === xvlog (all RTL once) ===
call "%XV%\xvlog.bat" -sv ^
    "%SRC%\rtl\gc_top.v" "%SRC%\rtl\gc_mark_engine.v" "%SRC%\rtl\gc_axi_read.v" ^
    "%SRC%\rtl\gc_bitmap.v" "%SRC%\rtl\gc_queue.v" "%SRC%\rtl\gc_freelist.v" ^
    "%SRC%\rtl\gc_dirty_fifo.v" "%SRC%\rtl\gc_regs.v" "%SRC%\sim\axi_proto_check.v" ^
    "%SRC%\sim\tb_flush_data.v" "%SRC%\sim\tb_stale_ar_flush.v" "%SRC%\sim\tb_start_while_busy.v"
if errorlevel 1 goto :fail

for %%T in (tb_flush_data tb_stale_ar_flush tb_start_while_busy) do (
    echo === %%T ===
    call "%XV%\xelab.bat" %%T -s %%T --mt 8 > %%T_xelab.log 2>&1
    if errorlevel 1 (
        echo XELAB FAILED %%T
        set "FAILED=1"
    ) else (
        call "%XV%\xsim.bat" %%T -R > %%T.log 2>&1
        findstr /C:"[FAIL]" %%T.log >nul
        if not errorlevel 1 (
            echo FAIL LINES in %%T
            findstr /C:"[FAIL]" %%T.log
            set "FAILED=1"
        ) else (
            findstr /C:"PASS" %%T.log >nul
            if errorlevel 1 ( echo NO PASS BANNER %%T & set "FAILED=1" ) else ( echo done %%T )
        )
    )
)

echo === PORT TB DONE ===
if defined FAILED exit /b 1
exit /b 0

:fail
echo === BUILD FAILED ===
exit /b 1
