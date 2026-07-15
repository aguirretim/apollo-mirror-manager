@echo off
setlocal
cd /d "%~dp0"
title Apollo Mirror Manager - Uninstall

echo(
echo   ==========================================================
echo      Apollo Mirror Manager - Uninstall
echo   ==========================================================
echo(
echo   This stops the background watcher and removes the
echo   watchdog task and shortcuts. It does NOT remove any
echo   Moonlight tiles you added (remove those in the app first)
echo   and it does NOT uninstall any of your games.
echo(
pause

echo(
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
echo(
pause
endlocal
