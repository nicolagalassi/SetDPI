#Requires -Version 5.1

<#
    DpiScaling.psm1

    Pure PowerShell port of SetDPI (https://github.com/imniko/SetDPI).
    Reads and changes the Windows "Scale and layout" (DPI scaling) value from a
    script, without shipping or compiling any executable.

    The interop below is a 1:1 translation of DpiHelper.cpp / SetDpi.cpp: the OS
    exposes DPI scaling through the undocumented DISPLAYCONFIG_DEVICE_INFO_TYPE
    values -3 (get) and -4 (set) of DisplayConfig{Get,Set}DeviceInfo.

    Exported commands:
        Get-DpiDisplay              list active displays and their scaling
        Get-DpiScaling              current scaling of one display, in percent
        Set-DpiScaling              change the scaling of one display
        Start-ProcessAtDpiScaling   run a program at a given scaling, restore after
#>

Set-StrictMode -Version Latest

# Set in the module scope on purpose: functions exported by a module do not
# inherit the preference variables of the caller, and every failure in here
# (a failed API call, a scaling that did not apply) has to be terminating.
$ErrorActionPreference = 'Stop'

if (-not ('SetDpi.DpiApi' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace SetDpi
{
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID
    {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_SOURCE_INFO
    {
        public LUID adapterId;
        public uint id;
        public uint modeInfoIdx;
        public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_RATIONAL
    {
        public uint Numerator;
        public uint Denominator;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_TARGET_INFO
    {
        public LUID adapterId;
        public uint id;
        public uint modeInfoIdx;
        public uint outputTechnology;
        public uint rotation;
        public uint scaling;
        public DISPLAYCONFIG_RATIONAL refreshRate;
        public uint scanLineOrdering;
        public int targetAvailable;
        public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_INFO
    {
        public DISPLAYCONFIG_PATH_SOURCE_INFO sourceInfo;
        public DISPLAYCONFIG_PATH_TARGET_INFO targetInfo;
        public uint flags;
    }

    // The union payload of a mode info is never read here, so it stays opaque;
    // only the total size (64 bytes) has to match what the OS writes.
    [StructLayout(LayoutKind.Sequential, Size = 64)]
    public struct DISPLAYCONFIG_MODE_INFO
    {
        public uint infoType;
        public uint id;
        public LUID adapterId;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_DEVICE_INFO_HEADER
    {
        public int type;
        public uint size;
        public LUID adapterId;
        public uint id;
    }

    // Min, max, suggested and currently applied scaling, all relative to the
    // value the OS recommends for the source.
    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_SOURCE_DPI_SCALE_GET
    {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public int minScaleRel;
        public int curScaleRel;
        public int maxScaleRel;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_SOURCE_DPI_SCALE_SET
    {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public int scaleRel;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAYCONFIG_TARGET_DEVICE_NAME
    {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public uint flags;
        public uint outputTechnology;
        public ushort edidManufactureId;
        public ushort edidProductCodeId;
        public uint connectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string monitorFriendlyDeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string monitorDevicePath;
    }

    public class Display
    {
        public int Index;
        public string Name;
        public bool IsInternal;
        public LUID AdapterId;
        public uint SourceId;
        public uint TargetId;
    }

    public class ScalingInfo
    {
        public uint Minimum = 100;
        public uint Maximum = 100;
        public uint Current = 100;
        public uint Recommended = 100;
        public bool IsValid = false;
    }

    /*
     * Small UI helpers for scripts launched from a batch file or a shortcut:
     * getting rid of the console window that the launcher opens, and still being
     * able to report an error once that window is gone.
     */
    public static class Ui
    {
        [DllImport("kernel32.dll")]
        private static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

        private const int SW_HIDE = 0;
        private const uint MB_ICONERROR = 0x00000010;
        private const uint MB_SETFOREGROUND = 0x00010000;
        private const uint MB_TOPMOST = 0x00040000;

        public static bool HideConsole()
        {
            IntPtr window = GetConsoleWindow();
            if (window == IntPtr.Zero)
            {
                return false;
            }
            return ShowWindow(window, SW_HIDE);
        }

        public static void ShowError(string message, string caption)
        {
            MessageBoxW(IntPtr.Zero, message, caption, MB_ICONERROR | MB_SETFOREGROUND | MB_TOPMOST);
        }
    }

    internal static class NativeMethods
    {
        [DllImport("user32.dll")]
        internal static extern int GetDisplayConfigBufferSizes(
            uint flags, out uint numPathArrayElements, out uint numModeInfoArrayElements);

        [DllImport("user32.dll")]
        internal static extern int QueryDisplayConfig(
            uint flags,
            ref uint numPathArrayElements, [Out] DISPLAYCONFIG_PATH_INFO[] pathArray,
            ref uint numModeInfoArrayElements, [Out] DISPLAYCONFIG_MODE_INFO[] modeInfoArray,
            IntPtr currentTopologyId);

        [DllImport("user32.dll")]
        internal static extern int DisplayConfigGetDeviceInfo(
            ref DISPLAYCONFIG_SOURCE_DPI_SCALE_GET requestPacket);

        [DllImport("user32.dll")]
        internal static extern int DisplayConfigGetDeviceInfo(
            ref DISPLAYCONFIG_TARGET_DEVICE_NAME requestPacket);

        [DllImport("user32.dll")]
        internal static extern int DisplayConfigSetDeviceInfo(
            ref DISPLAYCONFIG_SOURCE_DPI_SCALE_SET setPacket);
    }

    public static class DpiApi
    {
        /*
         * The OS reports DPI scaling relative to the recommended value, so the
         * absolute percentages have to be looked up in this table (values
         * observed and extrapolated from the Settings app).
         */
        public static readonly uint[] DpiVals =
            new uint[] { 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500 };

        private const uint QDC_ONLY_ACTIVE_PATHS = 2;
        private const int ERROR_SUCCESS = 0;
        private const int ERROR_INSUFFICIENT_BUFFER = 122;
        private const int DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME = 2;
        private const int DISPLAYCONFIG_DEVICE_INFO_GET_DPI_SCALE = -3;
        private const int DISPLAYCONFIG_DEVICE_INFO_SET_DPI_SCALE = -4;
        private const uint DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INTERNAL = 0x80000000;

        static DpiApi()
        {
            // Mirrors the asserts in DpiHelper.cpp: if these ever change, the OS
            // altered the undocumented packets this port relies on.
            if (Marshal.SizeOf(typeof(DISPLAYCONFIG_SOURCE_DPI_SCALE_GET)) != 0x20 ||
                Marshal.SizeOf(typeof(DISPLAYCONFIG_SOURCE_DPI_SCALE_SET)) != 0x18)
            {
                throw new InvalidOperationException(
                    "Unexpected DPI scaling packet layout; the interop definitions are out of date.");
            }
        }

        public static bool IsSupportedScale(uint percent)
        {
            for (int i = 0; i < DpiVals.Length; i++)
            {
                if (DpiVals[i] == percent)
                {
                    return true;
                }
            }
            return false;
        }

        public static List<Display> GetDisplays()
        {
            List<Display> displays = new List<Display>();

            uint pathCount = 0;
            uint modeCount = 0;
            DISPLAYCONFIG_PATH_INFO[] paths = null;
            DISPLAYCONFIG_MODE_INFO[] modes = null;
            int status = ERROR_INSUFFICIENT_BUFFER;

            // The display set can change between the two calls, hence the retry.
            for (int attempt = 0; attempt < 5 && status == ERROR_INSUFFICIENT_BUFFER; attempt++)
            {
                status = NativeMethods.GetDisplayConfigBufferSizes(
                    QDC_ONLY_ACTIVE_PATHS, out pathCount, out modeCount);
                if (status != ERROR_SUCCESS)
                {
                    throw new InvalidOperationException(
                        "GetDisplayConfigBufferSizes() failed with error " + status);
                }

                paths = new DISPLAYCONFIG_PATH_INFO[pathCount];
                modes = new DISPLAYCONFIG_MODE_INFO[modeCount];
                status = NativeMethods.QueryDisplayConfig(
                    QDC_ONLY_ACTIVE_PATHS, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero);
            }

            if (status != ERROR_SUCCESS)
            {
                throw new InvalidOperationException("QueryDisplayConfig() failed with error " + status);
            }

            for (int i = 0; i < (int)pathCount; i++)
            {
                Display display = new Display();
                display.Index = i + 1;
                display.AdapterId = paths[i].targetInfo.adapterId;
                display.SourceId = paths[i].sourceInfo.id;
                display.TargetId = paths[i].targetInfo.id;
                display.Name = "Display " + (i + 1);

                DISPLAYCONFIG_TARGET_DEVICE_NAME deviceName = new DISPLAYCONFIG_TARGET_DEVICE_NAME();
                deviceName.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
                deviceName.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_TARGET_DEVICE_NAME));
                deviceName.header.adapterId = paths[i].targetInfo.adapterId;
                deviceName.header.id = paths[i].targetInfo.id;

                if (NativeMethods.DisplayConfigGetDeviceInfo(ref deviceName) == ERROR_SUCCESS)
                {
                    if (!String.IsNullOrEmpty(deviceName.monitorFriendlyDeviceName))
                    {
                        display.Name = deviceName.monitorFriendlyDeviceName;
                    }
                    display.IsInternal =
                        (deviceName.outputTechnology == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INTERNAL);
                }

                displays.Add(display);
            }

            return displays;
        }

        public static ScalingInfo GetScalingInfo(Display display)
        {
            if (display == null)
            {
                throw new ArgumentNullException("display");
            }

            ScalingInfo info = new ScalingInfo();

            DISPLAYCONFIG_SOURCE_DPI_SCALE_GET packet = new DISPLAYCONFIG_SOURCE_DPI_SCALE_GET();
            packet.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_DPI_SCALE;
            packet.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_SOURCE_DPI_SCALE_GET));
            packet.header.adapterId = display.AdapterId;
            packet.header.id = display.SourceId;

            if (NativeMethods.DisplayConfigGetDeviceInfo(ref packet) != ERROR_SUCCESS)
            {
                return info;
            }

            if (packet.curScaleRel < packet.minScaleRel)
            {
                packet.curScaleRel = packet.minScaleRel;
            }
            else if (packet.curScaleRel > packet.maxScaleRel)
            {
                packet.curScaleRel = packet.maxScaleRel;
            }

            int minAbs = Math.Abs(packet.minScaleRel);
            if (DpiVals.Length < minAbs + packet.maxScaleRel + 1)
            {
                // DpiVals is out of date with respect to this OS.
                return info;
            }

            info.Current = DpiVals[minAbs + packet.curScaleRel];
            info.Recommended = DpiVals[minAbs];
            info.Maximum = DpiVals[minAbs + packet.maxScaleRel];
            info.IsValid = true;
            return info;
        }

        public static bool SetScaling(Display display, uint percent)
        {
            ScalingInfo info = GetScalingInfo(display);
            if (!info.IsValid)
            {
                return false;
            }

            if (percent == info.Current)
            {
                return true;
            }

            if (percent < info.Minimum)
            {
                percent = info.Minimum;
            }
            else if (percent > info.Maximum)
            {
                percent = info.Maximum;
            }

            int wantedIdx = -1;
            int recommendedIdx = -1;
            for (int i = 0; i < DpiVals.Length; i++)
            {
                if (DpiVals[i] == percent)
                {
                    wantedIdx = i;
                }
                if (DpiVals[i] == info.Recommended)
                {
                    recommendedIdx = i;
                }
            }

            if (wantedIdx == -1 || recommendedIdx == -1)
            {
                return false;
            }

            DISPLAYCONFIG_SOURCE_DPI_SCALE_SET packet = new DISPLAYCONFIG_SOURCE_DPI_SCALE_SET();
            packet.header.type = DISPLAYCONFIG_DEVICE_INFO_SET_DPI_SCALE;
            packet.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_SOURCE_DPI_SCALE_SET));
            packet.header.adapterId = display.AdapterId;
            packet.header.id = display.SourceId;
            packet.scaleRel = wantedIdx - recommendedIdx;

            return NativeMethods.DisplayConfigSetDeviceInfo(ref packet) == ERROR_SUCCESS;
        }
    }
}
'@
}

function Resolve-DpiDisplay {
    <#
    .SYNOPSIS
        Returns the native display object for a 1-based monitor index.
    #>
    [CmdletBinding()]
    param(
        [int] $Monitor = 1
    )

    $displays = [SetDpi.DpiApi]::GetDisplays()
    if ($displays.Count -eq 0) {
        throw 'No active display found.'
    }
    if ($Monitor -lt 1 -or $Monitor -gt $displays.Count) {
        throw "Invalid monitor index: $Monitor (found $($displays.Count) active display(s))."
    }

    return $displays[$Monitor - 1]
}

function Get-DpiDisplay {
    <#
    .SYNOPSIS
        Lists the active displays with their current, recommended and maximum scaling.
    .DESCRIPTION
        The Index column is the value to pass as -Monitor to the other commands. It
        follows the order returned by QueryDisplayConfig, the same order SetDPI.exe
        uses, which usually - but not always - matches the numbers shown by the
        Identify button in the Windows display settings.
    .EXAMPLE
        Get-DpiDisplay
    #>
    [CmdletBinding()]
    param()

    foreach ($display in [SetDpi.DpiApi]::GetDisplays()) {
        $info = [SetDpi.DpiApi]::GetScalingInfo($display)
        [PSCustomObject] @{
            Index       = $display.Index
            Name        = $display.Name
            Internal    = $display.IsInternal
            Current     = if ($info.IsValid) { [int] $info.Current } else { $null }
            Recommended = if ($info.IsValid) { [int] $info.Recommended } else { $null }
            Maximum     = if ($info.IsValid) { [int] $info.Maximum } else { $null }
        }
    }
}

function Get-DpiScaling {
    <#
    .SYNOPSIS
        Returns the current scaling of a display, in percent.
    .PARAMETER Monitor
        1-based monitor index; defaults to the first display.
    .EXAMPLE
        Get-DpiScaling
    .EXAMPLE
        Get-DpiScaling -Monitor 2
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [int] $Monitor = 1
    )

    $display = Resolve-DpiDisplay -Monitor $Monitor
    $info = [SetDpi.DpiApi]::GetScalingInfo($display)
    if (-not $info.IsValid) {
        throw "Could not read the scaling of monitor $Monitor ($($display.Name))."
    }

    return [int] $info.Current
}

function Set-DpiScaling {
    <#
    .SYNOPSIS
        Changes the scaling of a display, the same way the Windows display settings do.
    .PARAMETER Scale
        Scaling in percent. Must be one of 100, 125, 150, 175, 200, 225, 250, 300,
        350, 400, 450, 500 and within the range the display supports.
    .PARAMETER Monitor
        1-based monitor index; defaults to the first display.
    .PARAMETER NoRegistryUpdate
        Skips the HKCU AppliedDPI update that keeps the non-client areas of already
        running apps in sync. Only relevant for the first display.
    .PARAMETER PassThru
        Returns the scaling that ended up applied.
    .EXAMPLE
        Set-DpiScaling -Scale 100
    .EXAMPLE
        Set-DpiScaling -Scale 250 -Monitor 2
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [int] $Scale,

        [int] $Monitor = 1,

        [switch] $NoRegistryUpdate,

        [switch] $PassThru
    )

    if (-not [SetDpi.DpiApi]::IsSupportedScale([uint32] [Math]::Max(0, $Scale))) {
        throw "Invalid DPI scale value: $Scale. Supported values: $([SetDpi.DpiApi]::DpiVals -join ', ')."
    }

    $display = Resolve-DpiDisplay -Monitor $Monitor
    $info = [SetDpi.DpiApi]::GetScalingInfo($display)
    if (-not $info.IsValid) {
        throw "Could not read the scaling of monitor $Monitor ($($display.Name))."
    }
    if ($Scale -gt [int] $info.Maximum) {
        throw "Monitor $Monitor ($($display.Name)) supports at most $([int] $info.Maximum)%."
    }

    if (-not $PSCmdlet.ShouldProcess("monitor $Monitor ($($display.Name))", "set scaling to $Scale%")) {
        return
    }

    if (-not [SetDpi.DpiApi]::SetScaling($display, [uint32] $Scale)) {
        throw "Failed to set the scaling of monitor $Monitor ($($display.Name)) to $Scale%."
    }

    # The change is applied asynchronously by the OS, so poll for a moment.
    $applied = [int] $info.Current
    for ($i = 0; $i -lt 10; $i++) {
        $applied = [int] ([SetDpi.DpiApi]::GetScalingInfo($display)).Current
        if ($applied -eq $Scale) { break }
        Start-Sleep -Milliseconds 100
    }
    if ($applied -ne $Scale) {
        throw "The scaling of monitor $Monitor ($($display.Name)) is still $applied% after requesting $Scale%."
    }

    if (-not $NoRegistryUpdate -and $Monitor -eq 1) {
        # Same as SetDpi.cpp: keep Control Panel\Desktop\WindowMetrics\AppliedDPI
        # in sync so already running apps pick up the new scaling.
        try {
            Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' `
                -Name 'AppliedDPI' -Value ([int] (96 * $Scale / 100)) -Type DWord
        }
        catch {
            Write-Warning "Could not update HKCU AppliedDPI: $($_.Exception.Message)"
        }
    }

    if ($PassThru) {
        return $applied
    }
}

function Start-ProcessAtDpiScaling {
    <#
    .SYNOPSIS
        Runs a program while the display is set to a given scaling, then restores
        the previous scaling once the program exits.
    .DESCRIPTION
        Typical use: the desktop runs at 125% but one application has to be started
        at 100%. The scaling is changed first, the program is started afterwards so
        that it picks up the new value, and the original scaling is restored in a
        finally block when the program exits.

        Note that display scaling is a system-wide setting: everything else on that
        monitor is scaled at 100% too while the program runs.
    .PARAMETER FilePath
        Program to start.
    .PARAMETER ArgumentList
        Arguments passed to the program. The elements are joined with a space and
        used as the command line as-is, so arguments containing spaces have to
        carry their own quotes.
    .PARAMETER Scale
        Scaling to apply before starting the program. Defaults to 100.
    .PARAMETER Monitor
        1-based monitor index; defaults to the first display.
    .PARAMETER RestoreScale
        Scaling to restore after the program exits. Defaults to whatever was set
        before this command ran.
    .PARAMETER SettleMilliseconds
        Pause between the scaling change and the program start, so that the desktop
        has finished re-laying out. Defaults to 750 ms.
    .PARAMETER WaitForProcessName
        Extra process name (without .exe) to wait for after the started process
        exits. Useful for launchers that spawn the real application and quit.
    .PARAMETER NoRestore
        Leaves the new scaling in place instead of restoring the previous one.
    .EXAMPLE
        Start-ProcessAtDpiScaling -FilePath 'C:\Program Files\App\app.exe' -Scale 100
    .EXAMPLE
        Start-ProcessAtDpiScaling 'C:\App\app.exe' -ArgumentList '/fullscreen' -Scale 100 -Monitor 2
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $FilePath,

        [Parameter(Position = 1)]
        [string[]] $ArgumentList,

        [int] $Scale = 100,

        [int] $Monitor = 1,

        [int] $RestoreScale = 0,

        [int] $SettleMilliseconds = 750,

        [string] $WaitForProcessName,

        [string] $WorkingDirectory,

        [switch] $NoRestore
    )

    $originalScale = Get-DpiScaling -Monitor $Monitor
    $restoreTo = if ($RestoreScale -gt 0) { $RestoreScale } else { $originalScale }
    $changed = $false

    try {
        if ($originalScale -ne $Scale) {
            Write-Verbose "Monitor $Monitor : $originalScale% -> $Scale%"
            Set-DpiScaling -Scale $Scale -Monitor $Monitor
            $changed = $true
            if ($SettleMilliseconds -gt 0) {
                Start-Sleep -Milliseconds $SettleMilliseconds
            }
        }

        # System.Diagnostics.Process instead of Start-Process: the process object
        # returned by Start-Process -PassThru does not keep the process handle, so
        # its ExitCode reads back as 0 whatever the program returned.
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        # ShellExecute, so shortcuts, batch files and elevation manifests behave
        # like a double click in Explorer.
        $psi.UseShellExecute = $true
        if ($ArgumentList) { $psi.Arguments = ($ArgumentList -join ' ') }
        if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

        $exitCode = 0
        $process = [System.Diagnostics.Process]::Start($psi)
        if ($process) {
            # Touch the handle so that ExitCode is still readable after the exit.
            try { $null = $process.Handle } catch { }

            Write-Verbose "Started '$FilePath' (PID $($process.Id)), waiting for it to exit."
            # Polling instead of WaitForExit() so that Ctrl+C still reaches the finally block.
            while (-not $process.HasExited) {
                Start-Sleep -Milliseconds 200
            }
            try { $exitCode = $process.ExitCode } catch { $exitCode = 0 }
        }
        elseif (-not $WaitForProcessName) {
            # ShellExecute handed the file to an already running instance, so there
            # is nothing to wait for and the scaling would be restored immediately.
            throw "'$FilePath' was handed over to a running instance; use -WaitForProcessName to tell the script what to wait for."
        }

        if ($WaitForProcessName) {
            $name = $WaitForProcessName -replace '\.exe$', ''
            Write-Verbose "Waiting for every '$name' process to exit."
            while (@(Get-Process -Name $name -ErrorAction SilentlyContinue).Count -gt 0) {
                Start-Sleep -Milliseconds 500
            }
        }

        return $exitCode
    }
    finally {
        if ($changed -and -not $NoRestore) {
            Write-Verbose "Restoring monitor $Monitor to $restoreTo%"
            try {
                Set-DpiScaling -Scale $restoreTo -Monitor $Monitor
            }
            catch {
                Write-Warning "Could not restore the scaling to $restoreTo%: $($_.Exception.Message)"
            }
        }
    }
}

Export-ModuleMember -Function Get-DpiDisplay, Get-DpiScaling, Set-DpiScaling, Start-ProcessAtDpiScaling
