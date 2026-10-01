@echo off
chcp 936 >nul
title SNNU Auto Login - Enable Auto-start
cd /d "%~dp0"
for %%f in ("%~dp0*.ps1") do if not defined SNNUPS1 set "SNNUPS1=%%~ff"
if not defined SNNUPS1 (
  echo [ERROR] SNNU auto-login script *.ps1 not found in this folder.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%SNNUPS1%" -Action Install
echo.
pause
