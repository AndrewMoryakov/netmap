@echo off
chcp 65001 >nul
rem Local network map (read-only, loopback only). Close this window to stop it.
rem PowerShell 7 from the Store: if pwsh is not on PATH, use its alias in WindowsApps
set "NETMAP_FROM_CMD=1"
set "PWSH=pwsh"
where pwsh >nul 2>nul || set "PWSH=%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe"
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0netmap.ps1"
echo.
echo Exit code: %ERRORLEVEL%  (log: %~dp0netmap.log)
pause
