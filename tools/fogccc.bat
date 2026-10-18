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
powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0monitor_com5.ps1" -Plain -NoBoardStats
