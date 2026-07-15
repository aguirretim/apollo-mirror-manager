@echo off
setlocal
title Apollo Mirror Manager

rem Launches the installed app. The app asks for admin once (UAC) because
rem Apollo's config lives in Program Files - that's expected.

set "APP=%LOCALAPPDATA%\ApolloScripts\mirror-manager.vbs"

if exist "%APP%" (
  start "" wscript.exe "%APP%"
  goto :eof
)

rem Not installed yet - try running straight from this folder.
if exist "%~dp0scripts\mirror-manager.vbs" (
  start "" wscript.exe "%~dp0scripts\mirror-manager.vbs"
  goto :eof
)

echo Could not find Apollo Mirror Manager.
echo Please run START-HERE.cmd first to install it.
echo.
pause