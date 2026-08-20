@echo off
rem Batch wrapper around RunAtScale.ps1: start a program at a given display
rem scaling and restore the previous scaling when it exits.
rem
rem   RunAtScale.cmd "C:\Program Files\App\app.exe"           run it at 100%
rem   RunAtScale.cmd "C:\App\app.exe" 100 2                   at 100% on monitor 2
rem   RunAtScale.cmd "C:\App\app.exe" 100 1 hidden            without a console window
rem
rem An executable can also be dragged and dropped onto this file.
setlocal

set "PROGRAM=%~1"
if not defined PROGRAM (
    echo Usage: %~nx0 "C:\path\to\program.exe" [scale] [monitor] [hidden]
    exit /b 1
)

set "SCALE=%~2"
if not defined SCALE set "SCALE=100"

set "MONITOR=%~3"
if not defined MONITOR set "MONITOR=1"

rem With "hidden" the console window is closed as soon as the script starts and
rem errors are reported in a message box instead.
set "HIDDENFLAG="
if /i "%~4"=="hidden" set "HIDDENFLAG=-Hidden"

powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0RunAtScale.ps1" -Program "%PROGRAM%" -Scale %SCALE% -Monitor %MONITOR% %HIDDENFLAG%
exit /b %ERRORLEVEL%
