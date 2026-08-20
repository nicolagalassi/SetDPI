#Requires -Version 5.1
<#
.SYNOPSIS
    Command line front end for the DpiScaling module: same arguments as SetDPI.exe,
    without the executable.
.DESCRIPTION
    .\SetDpi.ps1 <scale|get|value|list> [monitor index]

    The monitor index is 1-based and can be omitted to address the first display.
.EXAMPLE
    .\SetDpi.ps1 125
    Sets the first display to 125%.
.EXAMPLE
    .\SetDpi.ps1 250 2
    Sets the second display to 250%.
.EXAMPLE
    .\SetDpi.ps1 get 2
    Prints "Current Resolution: 250".
.EXAMPLE
    .\SetDpi.ps1 value 2
    Prints "250", for use in other scripts.
.EXAMPLE
    .\SetDpi.ps1 list
    Prints every active display with its index and scaling.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Scale,

    [Parameter(Position = 1)]
    [int] $Monitor = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'DpiScaling.psm1') -Force

if (-not $Scale) {
    Write-Host '1. argument: scale in percent, or "get" to print the current value, "value" to print it unformatted, "list" to list the displays'
    Write-Host '2. argument: monitor index (1-based), leave empty to use the first display'
    exit 0
}

try {
    switch -Regex ($Scale) {
        '^(?i)list$' {
            Get-DpiDisplay | Format-Table -AutoSize | Out-String | Write-Host -NoNewline
            break
        }
        '^(?i)get$' {
            Write-Host "Current Resolution: $(Get-DpiScaling -Monitor $Monitor)"
            break
        }
        '^(?i)value$' {
            Write-Host (Get-DpiScaling -Monitor $Monitor)
            break
        }
        '^\d+$' {
            Set-DpiScaling -Scale ([int] $Scale) -Monitor $Monitor
            break
        }
        default {
            throw "Invalid DPI scale value: $Scale"
        }
    }
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

exit 0
