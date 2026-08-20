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
    Hides the console window of the launcher as soon as the script starts, for
    double clickable shortcuts. Errors are reported in a message box instead,
    since there is no window left to print them to.
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

    [switch] $Hidden
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'DpiScaling.psm1') -Force

if ($Hidden) {
    # Never let a failure to hide the window stop the program from starting.
    try { [void] [SetDpi.Ui]::HideConsole() } catch { }
}

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
