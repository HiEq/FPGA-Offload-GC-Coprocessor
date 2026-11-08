@echo off
chcp 65001 >nul
rem ============================================================
rem run_dump_tb.bat - bitmap DMA dump end-to-end check.
rem   The bitmap holds a unique pattern per word; after a full dump every
rem   32-bit word in the DDR model must equal the bitmap word at the same
rem   index.  A one-word address lag fails 28672/32768 words.
rem   Requires: DUMP_RESULT OK
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
set CACHE=%~dp0..\..\Cache\dump_tb
if not exist "%CACHE%" mkdir "%CACHE%"
cd /d "%CACHE%"

echo === xvlog ===
call "%XV%\xvlog.bat" -sv ^
    "%SRC%\rtl\gc_dump.v" "%SRC%\rtl\gc_bitmap.v" "%SRC%\sim\tb_gc_dump.v"
if errorlevel 1 (
    echo XVLOG FAILED
    exit /b 1
)

echo === xelab ===
call "%XV%\xelab.bat" tb_gc_dump -s tb_gc_dump --mt 8 > dump_xelab.log 2>&1
if errorlevel 1 (
    echo XELAB FAILED
    type dump_xelab.log
    exit /b 1
)

echo === xsim ===
call "%XV%\xsim.bat" tb_gc_dump -R > dump.log 2>&1
findstr /C:"DUMP_RESULT OK" dump.log >nul
if errorlevel 1 (
    echo DUMP TB FAILED
    type dump.log
    exit /b 1
)
echo done tb_gc_dump
exit /b 0
