# SetDPI without the executable

Same functionality as `SetDPI.exe`, implemented in PowerShell so it can be run
from a `.ps1` script, a `.cmd` batch file, a shortcut or the Task Scheduler on a
machine where you cannot deploy a compiled binary.

The interop in `DpiScaling.psm1` is a direct translation of `DpiHelper.cpp`: the
scaling is read and written through the undocumented
`DISPLAYCONFIG_DEVICE_INFO_TYPE` values `-3` and `-4` of
`DisplayConfigGetDeviceInfo` / `DisplayConfigSetDeviceInfo`, exactly like the C++
version. No admin rights are needed.

## Files

| File                   | What it is                                                      |
| ---------------------- | --------------------------------------------------------------- |
| `DpiScaling.psm1`      | The module: `Get-DpiDisplay`, `Get-DpiScaling`, `Set-DpiScaling`, `Start-ProcessAtDpiScaling` |
| `SetDpi.ps1`           | Command line front end with the same arguments as `SetDPI.exe`  |
| `RunAtScale.ps1`       | Starts a program at a given scaling and restores the previous one on exit |
| `SetDpi.cmd`           | Batch wrapper for `SetDpi.ps1`                                   |
| `RunAtScale.cmd`       | Batch wrapper for `RunAtScale.ps1`                               |
| `RunAt100.example.cmd` | Copy, edit the three variables at the top, double click          |

Keep the files together in one folder: the `.ps1` scripts import the module from
their own directory, and the `.cmd` wrappers call the scripts next to them.

## Run one program at 100% while Windows stays at 125%

This is the main use case. The scaling is lowered first, the program is started
afterwards so that it picks up 100%, and the original scaling is restored as soon
as the program is closed - also when the script is interrupted with Ctrl+C.

Batch:

```bat
RunAtScale.cmd "C:\Program Files\MyApp\MyApp.exe"
```

PowerShell:

```powershell
.\RunAtScale.ps1 -Program "C:\Program Files\MyApp\MyApp.exe" -Scale 100
```

Useful options:

```powershell
# second monitor, restore an explicit value instead of the one found at start
.\RunAtScale.ps1 -Program "C:\App\app.exe" -Scale 100 -Monitor 2 -RestoreScale 125

# pass arguments to the program
.\RunAtScale.ps1 -Program "C:\App\app.exe" -Arguments '/nologo'

# the executable is only a launcher: wait for the real process instead
.\RunAtScale.ps1 -Program "C:\App\launcher.exe" -WaitFor 'realapp'

# leave the scaling at 100% after the program exits
.\RunAtScale.ps1 -Program "C:\App\app.exe" -KeepScale
```

For a double clickable icon, copy `RunAt100.example.cmd`, set `PROGRAM`, `SCALE`
and `MONITOR` at the top of the copy and put it on the desktop or in the Start
menu. If the copy does not sit next to `RunAtScale.ps1` any more, point the
`TOOLS` variable at the folder that holds it.

### Getting rid of the console window

The wrapper keeps a console window open for as long as the program runs: that is
the process waiting to put the original scaling back, so it cannot simply exit.
It can be hidden though.

- **`-Hidden` / `hidden`** - the script hides the console as soon as it starts and
  reports errors in a message box instead. The window is still visible for the
  second or so that PowerShell needs to start up.

  ```bat
  RunAtScale.cmd "C:\App\app.exe" 100 1 hidden
  ```

  ```powershell
  .\RunAtScale.ps1 -Program "C:\App\app.exe" -Hidden
  ```

  In `RunAt100.example.cmd` this is the `HIDDEN` variable, set to 1 by default.

- **A minimized shortcut** - create a shortcut to the `.cmd` file and set Run to
  Minimized in its properties. Nothing flashes on screen, the wrapper just sits in
  the taskbar, which also makes it obvious that it is still running.

- **No window at all, not even the initial flash** - start it through the Windows
  script host, which has no console of its own. Put this next to the scripts as
  `RunAt100.vbs` and double click that instead. Some managed machines block `.vbs`
  and Microsoft has deprecated VBScript, so treat it as the last resort:

  ```vbs
  tools = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
  cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & tools & "\RunAtScale.ps1"" -Program ""C:\App\app.exe"" -Scale 100"
  CreateObject("WScript.Shell").Run cmd, 0, False
  ```

## Just read or change the scaling

`SetDpi.ps1` takes the same arguments as `SetDPI.exe`:

```powershell
.\SetDpi.ps1 125        # set the first display to 125%
.\SetDpi.ps1 250 2      # set the second display to 250%
.\SetDpi.ps1 get        # prints "Current Resolution: 125"
.\SetDpi.ps1 value 2    # prints "250", for use in other scripts
.\SetDpi.ps1 list       # lists the displays with their index and scaling
```

The same through the batch wrapper, which does not depend on the execution
policy of the machine:

```bat
SetDpi.cmd 125
SetDpi.cmd list
```

Or from your own PowerShell script:

```powershell
Import-Module .\DpiScaling.psm1

Get-DpiDisplay
Get-DpiScaling -Monitor 1
Set-DpiScaling -Scale 100 -Monitor 1
Start-ProcessAtDpiScaling -FilePath 'C:\App\app.exe' -Scale 100
```

## Notes and limitations

- Display scaling is a system-wide setting. While the program runs at 100%,
  everything else on that monitor is at 100% too. Windows offers no supported way
  to give a single window a different scaling than the rest of its display.
- Valid values are 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450 and 500,
  and only up to the maximum the display reports. Anything else is rejected.
- The monitor index is 1-based and follows the order returned by
  `QueryDisplayConfig`, the same order `SetDPI.exe` uses. It usually matches the
  numbers shown by the Identify button in the Windows display settings, but check
  with `.\SetDpi.ps1 list` when in doubt.
- Like the C++ version, changing the first display also updates
  `HKCU\Control Panel\Desktop\WindowMetrics\AppliedDPI`, so that already running
  applications follow the new scaling. Pass `-NoRegistryUpdate` to
  `Set-DpiScaling` to skip that.
- Some applications need a moment after the scaling change before they start.
  `RunAtScale.ps1` waits 750 ms by default; use `-SettleMs` to change it.
- If the machine forces the PowerShell execution policy, use the `.cmd` wrappers:
  they call `powershell.exe -ExecutionPolicy Bypass -File`, which only affects
  that single invocation.
- Windows PowerShell 5.1 and PowerShell 7 are both fine. The module compiles its
  interop with `Add-Type` on first use, which takes about a second; that requires
  PowerShell to run in full language mode.
