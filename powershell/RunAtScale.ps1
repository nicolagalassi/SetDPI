#Requires -Version 5.1
<#
.SYNOPSIS
    Starts a program at a given display scaling and restores the previous scaling
    when the program exits.
.DESCRIPTION
    Made for the case "Windows runs at 125% but this one application has to run at
    100%": the scaling is lowered first, the program is started afterwards so that
    it picks up the new value, and the original scaling is put back as soon as the
    program is closed - including when this script is interrupted with Ctrl+C.

    Display scaling is a system-wide setting, so everything else on that monitor is
    scaled at 100% too while the program runs.
.PARAMETER Program
    Program to start.
.PARAMETER Arguments
    Arguments passed to the program. The elements are joined with a space and used
    as the command line as-is, so arguments containing spaces have to carry their
    own quotes.
.PARAMETER Scale
    Scaling applied while the program runs. Defaults to 100.
.PARAMETER Monitor
    1-based monitor index. Run ".\SetDpi.ps1 list" to see the indexes.
.PARAMETER RestoreScale
    Scaling restored on exit. Defaults to the scaling that was active at start.
.PARAMETER WaitFor
    Extra process name to wait for after the started process exits, for programs
    whose executable is only a launcher (e.g. -WaitFor 'realapp').
.PARAMETER SettleMs
    Pause between the scaling change and the program start. Defaults to 750 ms.
.PARAMETER KeepScale
    Leaves the new scaling in place instead of restoring the previous one.
.PARAMETER Hidden
    Runs without any console window, for double clickable shortcuts. The script
    relaunches itself as a process that has no console at all and returns straight
    away, so the window of whatever started it closes instead of sitting there for
    the whole session. Errors are reported in a message box, and the exit code of
    the program is no longer passed on because nothing is left waiting for it.

    Hiding the existing window is not an option on Windows 11: its default
    terminal is Windows Terminal, which owns the window in another process, so
    ShowWindow() on the console handle does nothing.
.PARAMETER DetachedWorker
    Internal. Marks the relaunched process, so that it does the work instead of
    detaching again.
.EXAMPLE
    .\RunAtScale.ps1 -Program "C:\Program Files\App\app.exe"
.EXAMPLE
    .\RunAtScale.ps1 -Program "C:\App\app.exe" -Arguments '/nologo','/x' -Scale 100 -RestoreScale 125
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias('FilePath')]
    [string] $Program,

    [Parameter(Position = 1)]
    [Alias('ArgumentList')]
    [string[]] $Arguments,

    [int] $Scale = 100,

    [int] $Monitor = 1,

    [int] $RestoreScale = 0,

    [string] $WaitFor,

    [int] $SettleMs = 750,

    [string] $WorkingDirectory,

    [switch] $KeepScale,

    [switch] $Hidden,

    [switch] $DetachedWorker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Hidden -and -not $DetachedWorker) {
    # Relaunch without a console and let the caller's window close. This happens
    # before the module is imported, so the visible part is only the startup of
    # this process.
    function Format-CommandLineArgument {
        param([string] $Value)
        # Quoting rules of CommandLineToArgvW, which is what the child process uses
        # to split the command line again: a backslash only escapes a quote, so the
        # run of backslashes in front of one - including the closing one, for paths
        # that end with a separator - has to be doubled.
        $escaped = $Value -replace '(\\*)"', '$1$1\"'
        $escaped = $escaped -replace '(\\+)$', '$1$1'
        return '"' + $escaped + '"'
    }

    $childArguments = @(
        '-NoProfile'
        '-NonInteractive'
        '-ExecutionPolicy', 'Bypass'
        '-File', (Format-CommandLineArgument $PSCommandPath)
        '-Program', (Format-CommandLineArgument $Program)
        '-Scale', $Scale
        '-Monitor', $Monitor
        '-RestoreScale', $RestoreScale
        '-SettleMs', $SettleMs
        '-Hidden'
        '-DetachedWorker'
    )
    if ($Arguments) {
        # The module joins the elements with a space anyway, so one string is enough.
        $childArguments += '-Arguments', (Format-CommandLineArgument ($Arguments -join ' '))
    }
    if ($WaitFor) { $childArguments += '-WaitFor', (Format-CommandLineArgument $WaitFor) }
    if ($WorkingDirectory) { $childArguments += '-WorkingDirectory', (Format-CommandLineArgument $WorkingDirectory) }
    if ($KeepScale) { $childArguments += '-KeepScale' }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Process -Id $PID).Path
    $psi.Arguments = ($childArguments -join ' ')
    $psi.UseShellExecute = $false
    # No console for the child, so no window for any terminal to show.
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

    try {
        [void] [System.Diagnostics.Process]::Start($psi)
        exit 0
    }
    catch {
        Write-Host "Could not start the hidden process: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

Import-Module (Join-Path $PSScriptRoot 'DpiScaling.psm1') -Force

try {
    $splat = @{
        FilePath           = $Program
        Scale              = $Scale
        Monitor            = $Monitor
        RestoreScale       = $RestoreScale
        SettleMilliseconds = $SettleMs
        NoRestore          = $KeepScale
    }
    if ($Arguments) { $splat['ArgumentList'] = $Arguments }
    if ($WaitFor) { $splat['WaitForProcessName'] = $WaitFor }
    if ($WorkingDirectory) { $splat['WorkingDirectory'] = $WorkingDirectory }

    $exitCode = Start-ProcessAtDpiScaling @splat
    exit $exitCode
}
catch {
    if ($Hidden) {
        [SetDpi.Ui]::ShowError($_.Exception.Message, 'RunAtScale')
    }
    else {
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
    exit 1
}
