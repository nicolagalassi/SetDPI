@echo off
rem Batch wrapper around SetDpi.ps1, so the tool can be used from cmd, a shortcut
rem or the Task Scheduler without changing the PowerShell execution policy.
rem
rem   SetDpi.cmd 125          set the first display to 125%
rem   SetDpi.cmd 250 2        set the second display to 250%
rem   SetDpi.cmd get          print the current scaling
rem   SetDpi.cmd list         list the displays and their indexes
setlocal
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0SetDpi.ps1" %*
exit /b %ERRORLEVEL%
