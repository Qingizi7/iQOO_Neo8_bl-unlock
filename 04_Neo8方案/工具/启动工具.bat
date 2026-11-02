@echo off
setlocal
title iQOO Neo8 BL Tool
chcp 65001 >nul
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Neo8BL.ps1"
set "tool_exit=%errorlevel%"
echo.
pause
exit /b %tool_exit%
