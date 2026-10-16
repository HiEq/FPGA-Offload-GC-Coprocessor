@echo off
rem  FOGCCC console (COM5) - dashboard mode
rem  Terminal choice is free (conhost or Windows Terminal).
rem  No chcp 65001 on purpose (PS 5.1 + 65001 can break console input).
title FOGCCC console  (COM5)  dashboard
powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0monitor_com5.ps1"
