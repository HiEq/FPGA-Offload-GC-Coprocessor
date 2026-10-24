@echo off
chcp 65001 >nul
start "" notepad "%~dp0logs\serial.log"
