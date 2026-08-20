@echo off
rem Ready to use example: copy this file, edit the three values below and put the
rem copy on the desktop or in the Start menu. Double clicking it starts the
rem program at 100% while Windows stays configured at, say, 125%; closing the
rem program puts the original scaling back.
setlocal

rem --- edit these ------------------------------------------------------------
set "PROGRAM=C:\Program Files\MyApp\MyApp.exe"
set "SCALE=100"
set "MONITOR=1"
rem ---------------------------------------------------------------------------

powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0RunAtScale.ps1" -Program "%PROGRAM%" -Scale %SCALE% -Monitor %MONITOR%
exit /b %ERRORLEVEL%
