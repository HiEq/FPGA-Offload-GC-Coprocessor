@echo off
chcp 65001 >nul & rem allow-hardcoded: UTF-8 code page
start "" notepad "%~dp0logs\serial.log"
