@echo off
rem ============================================================
rem  FOGCCC console (COM5) - plain passthrough
rem
rem  Terminal choice is free: classic conhost or Windows Terminal both work.

rem
rem  Windows Terminal gestures (QuickEdit does not apply there):
rem     select : drag with the mouse (or Shift+drag)
rem     copy   : Ctrl+Shift+C
rem     paste  : Ctrl+Shift+V  (or right-click)
rem

rem
rem  Keyboard unlocks when 'linux login:' is seen, or after 10s of serial silence.
rem  Keep the input method on EN (US) while typing.
rem ============================================================
title FOGCCC console  (COM5)  plain passthrough
rem  serial-monitor.ps1 is the unified console shared with the LINUX-FPGA project.
rem  -WaitPortSec 300 : the console is normally started *before* the board is powered.
rem  -Log             : keep the fixed logs\serial.log name (log.bat opens it).
powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0serial-monitor.ps1" -Log "%~dp0logs\serial.log" -WaitPortSec 300
