@echo off
setlocal
cd /d "%~dp0"
title Apollo Mirror Manager - Setup

echo(
echo   ==========================================================
echo      Apollo Mirror Manager - Easy Setup
echo   ==========================================================
echo(
echo   This will:
echo     1. Unblock the files Windows flagged as "downloaded"
echo     2. Install the game-mirror system (no admin needed)
echo     3. Put "Apollo Mirror Manager" on your Desktop
echo(
echo   Nothing here changes your monitors or your desktop.
echo(
pause

echo(
echo   [1/2] Unblocking downloaded files...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse -File | Unblock-File" 2>nul

echo   [2/2] Running the installer...
echo(
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
set "RC=%ERRORLEVEL%"

rem Also unblock the copy that was placed in LocalAppData, just in case.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d = Join-Path $env:LOCALAPPDATA 'ApolloScripts'; if (Test-Path $d) { Get-ChildItem -LiteralPath $d -Recurse -File | Unblock-File }" 2>nul

echo(
if not "%RC%"=="0" (
  echo   ---------------------------------------------------------
  echo   Something went wrong during install ^(see the messages above^).
  echo   The most common cause is antivirus blocking the scripts.
  echo   See the README "Troubleshooting" section for help.
  echo   ---------------------------------------------------------
) else (
  echo   ---------------------------------------------------------
  echo   All set! Look for "Apollo Mirror Manager" on your Desktop.
  echo   Double-click it to open the app and add your games.
  echo   ---------------------------------------------------------
)
echo(
pause
endlocal
