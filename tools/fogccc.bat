@echo off
rem ============================================================
rem  FOGCCC console (COM5) - plain passthrough
rem
rem  Terminal choice is free: classic conhost or Windows Terminal both work.
rem  (The old "conhost.exe" forcing was a misdiagnosis - the real bug was a
rem   $null StringBuilder in the keyboard path, see notes F21.)
rem
rem  Windows Terminal gestures (QuickEdit does not apply there):
rem     select : drag with the mouse (or Shift+drag)
rem     copy   : Ctrl+Shift+C
rem     paste  : Ctrl+Shift+V  (or right-click)
rem
rem  No "chcp 65001": PS 5.1 + codepage 65001 can break console input, and all
rem  output here is ASCII anyway.
rem
rem  Keyboard unlocks when 'linux login:' is seen, or after 10s of serial silence.
rem  Keep the input method on EN (US) while typing.
rem ============================================================
title FOGCCC console  (COM5)  plain passthrough
powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0monitor_com5.ps1" -Plain -NoBoardStats
