@echo off
setlocal
title iQOO Neo8 Environment Check
chcp 65001 >nul
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0EnvCheck.ps1"
set "check_exit=%errorlevel%"
echo.
pause
exit /b %check_exit%
