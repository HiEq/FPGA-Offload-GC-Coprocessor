@echo off
chcp 65001 >nul
title FOGCCC console  (COM5)   raw while booting -> dashboard after Linux
powershell -ExecutionPolicy Bypass -NoExit -File "%~dp0monitor_com5.ps1"
