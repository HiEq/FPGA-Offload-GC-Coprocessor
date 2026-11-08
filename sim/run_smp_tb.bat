@echo off
chcp 65001 >nul
rem ============================================================
rem run_smp_tb.bat - Step 2 building blocks:
rem   tb_gc_bitmap4 : four independent bitmap banks
rem   tb_gc_push_arb : 2:1 round-robin push into the single queue
rem   Requires BM4_RESULT OK and ARB_RESULT OK
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
set CACHE=%~dp0..\..\Cache\smp_tb
if not exist "%CACHE%" mkdir "%CACHE%"
cd /d "%CACHE%"
set "FAILED="

echo === xvlog ===
call "%XV%\xvlog.bat" -sv ^
    "%SRC%\rtl\gc_bitmapN.v" "%SRC%\rtl\gc_push_arb.v" "%SRC%\rtl\gc_lane.v" ^
    "%SRC%\rtl\gc_push_fifo.v" ^
    "%SRC%\sim\tb_gc_bitmap4.v" "%SRC%\sim\tb_gc_bitmap2.v" ^
    "%SRC%\sim\tb_gc_push_arb.v" "%SRC%\sim\tb_gc_lane.v" ^
    "%SRC%\sim\tb_gc_push_fifo.v"
if errorlevel 1 (
    echo XVLOG FAILED
    exit /b 1
)

for %%T in (tb_gc_bitmap4 tb_gc_bitmap2 tb_gc_push_arb tb_gc_lane tb_gc_push_fifo) do (
    echo === %%T ===
    call "%XV%\xelab.bat" %%T -s %%T --mt 8 > %%T_xelab.log 2>&1
    if errorlevel 1 (
        echo XELAB FAILED %%T
        set "FAILED=1"
    ) else (
        call "%XV%\xsim.bat" %%T -R > %%T.log 2>&1
        findstr /C:"_RESULT OK" %%T.log >nul
        if errorlevel 1 (
            echo NO OK BANNER %%T
            type %%T.log
            set "FAILED=1"
        ) else ( echo done %%T )
    )
)

echo === SMP TB DONE ===
if defined FAILED exit /b 1
exit /b 0

