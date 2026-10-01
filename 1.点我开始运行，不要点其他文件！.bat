@echo off
rem ------------------------------------------------------------------
rem  This launcher is intentionally ASCII-only, so it can never break
rem  because of console code page / encoding issues.
rem  All Chinese messages come from the PowerShell script itself.
rem ------------------------------------------------------------------
chcp 936 >nul
title SNNU Auto Login - Config UI
cd /d "%~dp0"
for %%f in ("%~dp0*.ps1") do if not defined SNNUPS1 set "SNNUPS1=%%~ff"
if not defined SNNUPS1 (
  echo [ERROR] SNNU auto-login script *.ps1 not found in this folder.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%SNNUPS1%" -Action UI
echo.
pause
