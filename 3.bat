@echo off
rem ------------------------------------------------------------------
rem  Stop everything at once:
rem    1) stop the background daemon
rem    2) remove auto-start
rem    3) disconnect the current network session
rem  ASCII-only on purpose (no code page / encoding issues).
rem ------------------------------------------------------------------
chcp 936 >nul
title SNNU Auto Login - Stop And Disconnect
cd /d "%~dp0"
for %%f in ("%~dp0*.ps1") do if not defined SNNUPS1 set "SNNUPS1=%%~ff"
if not defined SNNUPS1 (
  echo [ERROR] SNNU auto-login script *.ps1 not found in this folder.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%SNNUPS1%" -Action StopAll -Disconnect
echo.
pause
