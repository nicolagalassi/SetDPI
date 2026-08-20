@echo off
rem Ready to use example: copy this file, edit the values below and put the copy
rem on the desktop or in the Start menu. Double clicking it starts the program at
rem 100% while Windows stays configured at, say, 125%; closing the program puts
rem the original scaling back.
setlocal

rem --- edit these ------------------------------------------------------------
set "PROGRAM=C:\Program Files\MyApp\MyApp.exe"
set "SCALE=100"
set "MONITOR=1"
rem 1 = hide the console window while the program runs (errors still come up in a
rem message box), 0 = keep it visible, which is handy while setting things up
set "HIDDEN=1"
rem Folder holding RunAtScale.ps1 and DpiScaling.psm1. %~dp0 means "next to this
rem file"; put the full path here instead if you move this copy somewhere else,
rem for example set "TOOLS=C:\Tools\SetDpi\"  (keep the trailing backslash)
set "TOOLS=%~dp0"
rem ---------------------------------------------------------------------------

if not exist "%TOOLS%RunAtScale.ps1" (
    echo RunAtScale.ps1 not found in "%TOOLS%" - set TOOLS to the folder holding it.
    pause
    exit /b 1
)

set "HIDDENFLAG="
if "%HIDDEN%"=="1" set "HIDDENFLAG=-Hidden"

powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%TOOLS%RunAtScale.ps1" -Program "%PROGRAM%" -Scale %SCALE% -Monitor %MONITOR% %HIDDENFLAG%
exit /b %ERRORLEVEL%
