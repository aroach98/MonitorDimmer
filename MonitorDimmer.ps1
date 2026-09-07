<#
    MonitorDimmer.ps1
    A free replacement for DisplayFusion's "Monitor Fading" feature.

    What it does:
      * Puts a dim (semi-transparent, click-through) overlay on every monitor.
      * Automatically un-dims whichever monitor holds the focused window.
      * Global hotkeys let you toggle it, change dim level, and quit.

    How it works (same technique DisplayFusion uses):
      * One borderless, topmost, LAYERED, click-through window per monitor.
      * A timer checks the foreground window's monitor and shows/hides overlays.
      * RegisterHotKey gives us system-wide keyboard shortcuts.

    Default hotkeys:
      Ctrl + Alt + F        Toggle dimming on/off
      Ctrl + Alt + Up       Dim more (darker)
      Ctrl + Alt + Down     Dim less (lighter)
      Ctrl + Alt + Q        Quit

    Run:  double-click Start-MonitorDimmer.bat (or the "Monitor Dimmer" shortcut).
    Those launch it under "conhost.exe --headless", which is the only way to get
    a PowerShell script with NO console window at all on Windows 11 -- plain
    "-WindowStyle Hidden" still creates a console (and Windows Terminal ignores
    the hide entirely), and closing that console kills the dimmer.

    The dimmer runs as a background process with a tray icon (bottom-right,
    near the clock). Right-click it to toggle / adjust / quit.
#>

# ----------------------------------------------------------------------------
# Single-instance guard: launching the pinned shortcut while an instance is
# already running would otherwise stack a second set of overlays.
# ----------------------------------------------------------------------------
$singleInstanceMutex = New-Object System.Threading.Mutex($false, 'Local\MonitorDimmer-SingleInstance')
if (-not $singleInstanceMutex.WaitOne(0)) {
    exit
}

# ----------------------------------------------------------------------------
# Settings you can tweak
# ----------------------------------------------------------------------------
$DimLevelStart = 1.00      # 0.0 = invisible, 1.0 = fully black.
$DimColor      = 'Black'   # Any .NET color name: Black, DimGray, Navy, etc.
$OpacityStep   = 0.10      # How much Up/Down changes the dim.
$StartActive   = $true     # Start with dimming already on?
$PollMs        = 160       # How often we re-check which monitor has focus.

# How long a monitor must hold focus before the overlays actually move.
# Anything shorter than this is treated as a transient blip and ignored, which
# is what stops a background console window, a notification toast, or an
# installer stealing focus for half a second from blacking out the screen you
# are actually watching. Raise it if flicker still gets through; lower it if
# following your focus between monitors feels sluggish.
$SwitchDelayMs = 450

# ----------------------------------------------------------------------------
# Make the process per-monitor DPI aware so overlays cover mixed-DPI monitors
# exactly. Must happen before any window is created.
# ----------------------------------------------------------------------------
Add-Type -Namespace Win -Name Dpi -MemberDefinition @"
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(System.IntPtr value);
"@
# DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4 (silently no-ops on old Windows)
try { [Win.Dpi]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null } catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ----------------------------------------------------------------------------
# Native helpers: the extended-window-style flags that make overlays
# click-through, plus the calls we need to decide whether the foreground
# window is a real app window worth following.
# (We use .NET's Screen.FromHandle to map a window to its monitor, so no
#  monitor-handle P/Invoke is needed.)
# ----------------------------------------------------------------------------
Add-Type -Namespace Win -Name Native -MemberDefinition @"
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern System.IntPtr GetForegroundWindow();

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool IsWindowVisible(System.IntPtr hwnd);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool GetWindowRect(System.IntPtr hwnd, out RECT rect);

    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Auto)]
    public static extern int GetClassName(System.IntPtr hwnd, System.Text.StringBuilder name, int maxCount);

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
    public static extern int GetWindowLong(System.IntPtr hwnd, int index);

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
    public static extern int SetWindowLong(System.IntPtr hwnd, int index, int newLong);

    public const int GWL_EXSTYLE      = -20;
    public const int WS_EX_LAYERED    = 0x00080000;
    public const int WS_EX_TRANSPARENT= 0x00000020;  // click-through
    public const int WS_EX_TOOLWINDOW = 0x00000080;  // keep out of Alt-Tab
    public const int WS_EX_NOACTIVATE = 0x08000000;  // never steal focus
"@

function Make-ClickThrough($form) {
    $h  = $form.Handle
    $ex = [Win.Native]::GetWindowLong($h, [Win.Native]::GWL_EXSTYLE)
    $ex = $ex -bor [Win.Native]::WS_EX_LAYERED `
              -bor [Win.Native]::WS_EX_TRANSPARENT `
              -bor [Win.Native]::WS_EX_TOOLWINDOW `
              -bor [Win.Native]::WS_EX_NOACTIVATE
    [Win.Native]::SetWindowLong($h, [Win.Native]::GWL_EXSTYLE, $ex) | Out-Null
}

# Shell surfaces that briefly own the foreground during Start menu / Alt-Tab /
# toast animations. They live on the primary monitor, so following them would
# yank the un-dimmed monitor over there for a few frames.
$IgnoredClasses = @(
    'Progman'                        # desktop
    'WorkerW'                        # desktop wallpaper host
    'Shell_TrayWnd'                  # taskbar
    'Shell_SecondaryTrayWnd'
    'NotifyIconOverflowWindow'
    'ForegroundStaging'              # transient staging window during focus handoff
    'XamlExplorerHostIslandWindow'   # Start / Search / Alt-Tab
    'MultitaskingViewFrame'          # Task View
    'Windows.UI.Core.CoreWindow'     # toasts and other UWP shell surfaces
    'TaskListThumbnailWnd'
    'tooltips_class32'
)

# ----------------------------------------------------------------------------
# Build one overlay form per monitor.
# ----------------------------------------------------------------------------
$script:OverlayHandles = New-Object 'System.Collections.Generic.HashSet[System.IntPtr]'

function New-Overlays {
    $list = @()
    $script:OverlayHandles.Clear()
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $f = New-Object System.Windows.Forms.Form
        $f.FormBorderStyle = 'None'
        $f.StartPosition   = 'Manual'
        $f.ShowInTaskbar   = $false
        $f.TopMost         = $true
        $f.BackColor       = [System.Drawing.Color]::FromName($DimColor)
        $f.Opacity         = $DimLevelStart
        $f.Bounds          = $screen.Bounds
        # Remember which physical monitor this overlay belongs to, and what
        # opacity is actually applied, so the timer can skip redundant writes.
        $f | Add-Member -NotePropertyName ScreenName     -NotePropertyValue $screen.DeviceName
        $f | Add-Member -NotePropertyName AppliedOpacity -NotePropertyValue $DimLevelStart
        $list += $f
    }
    # Realize handles + make them click-through, then hide until we decide.
    foreach ($f in $list) {
        $f.Show()
        Make-ClickThrough $f
        [void]$script:OverlayHandles.Add($f.Handle)
        $f.Hide()
    }
    return ,$list
}

$overlays = New-Overlays

# ----------------------------------------------------------------------------
# Controller: a hidden form that owns the hotkeys + the refresh timer.
# Custom state is stored under names that don't collide with Form members.
# ----------------------------------------------------------------------------
$controller = New-Object System.Windows.Forms.Form
$controller.WindowState     = 'Minimized'
$controller.ShowInTaskbar   = $false
$controller.FormBorderStyle = 'FixedToolWindow'
$controller.Opacity         = 0
$controller.Add_Shown({ $controller.Hide() })

$controller | Add-Member -NotePropertyName IsActive -NotePropertyValue $StartActive
$controller | Add-Member -NotePropertyName DimLevel -NotePropertyValue $DimLevelStart
$controller | Add-Member -NotePropertyName Overlays -NotePropertyValue $overlays
# The monitor the overlays are currently committed to, plus the monitor that is
# campaigning to replace it and how long it has been campaigning.
$controller | Add-Member -NotePropertyName ActiveScreen   -NotePropertyValue $null
$controller | Add-Member -NotePropertyName Candidate      -NotePropertyValue $null
$controller | Add-Member -NotePropertyName CandidateSince -NotePropertyValue ([DateTime]::MinValue)

# Returns the DeviceName of the monitor holding the focused window, or $null
# when the foreground window is something we should not follow. Returning $null
# matters: Screen.FromHandle answers "primary monitor" for a null or bogus
# handle, and acting on that is exactly what used to black out the monitor you
# were watching whenever anything hiccuped.
function Get-ActiveScreenName {
    $fg = [Win.Native]::GetForegroundWindow()

    # No foreground window at all -- normal during focus handoffs and fullscreen
    # transitions. Keep whatever we last committed to.
    if ($fg -eq [System.IntPtr]::Zero)           { return $null }
    if ($script:OverlayHandles.Contains($fg))    { return $null }   # one of our own overlays
    if (-not [Win.Native]::IsWindowVisible($fg)) { return $null }

    $sb = New-Object System.Text.StringBuilder 256
    [void][Win.Native]::GetClassName($fg, $sb, $sb.Capacity)
    if ($IgnoredClasses -contains $sb.ToString()) { return $null }

    # Zero-size and off-screen windows resolve to the primary monitor too.
    $r = New-Object Win.Native+RECT
    if (-not [Win.Native]::GetWindowRect($fg, [ref]$r)) { return $null }
    if (($r.Right - $r.Left) -le 1 -or ($r.Bottom - $r.Top) -le 1) { return $null }

    return [System.Windows.Forms.Screen]::FromHandle($fg).DeviceName
}

function Update-Overlays {
    if ($controller.IsActive) {
        $name = Get-ActiveScreenName
        if ($null -ne $name) {
            if ($name -ne $controller.Candidate) {
                $controller.Candidate      = $name
                $controller.CandidateSince = Get-Date
            }
            if ($null -eq $controller.ActiveScreen) {
                # First resolve after startup or a display change: commit at once
                # so the overlays are not wrong for half a second on launch.
                $controller.ActiveScreen = $name
            }
            elseif ($name -ne $controller.ActiveScreen -and
                    ((Get-Date) - $controller.CandidateSince).TotalMilliseconds -ge $SwitchDelayMs) {
                $controller.ActiveScreen = $name
            }
        }
        # $name -eq $null -> hold the last committed monitor. Doing nothing here
        # is the entire point.
    }

    foreach ($f in $controller.Overlays) {
        if (-not $controller.IsActive) {
            if ($f.Visible) { $f.Hide() }
            continue
        }
        # Only write Opacity when it actually changed. Assigning it every tick
        # re-pushes layered-window attributes ~6x/sec on every monitor, which is
        # pointless compositor work while a video is playing.
        if ($f.AppliedOpacity -ne $controller.DimLevel) {
            $f.Opacity        = $controller.DimLevel
            $f.AppliedOpacity = $controller.DimLevel
        }
        # Dim every monitor EXCEPT the one holding the focused window.
        $shouldDim = ($f.ScreenName -ne $controller.ActiveScreen)
        if ($shouldDim -and -not $f.Visible)     { $f.Show(); Make-ClickThrough $f }
        elseif (-not $shouldDim -and $f.Visible) { $f.Hide() }
    }
}

# ----------------------------------------------------------------------------
# Rebuild overlays when monitors are added, removed, or rearranged. Without
# this the overlays keep the old bounds and the old \\.\DISPLAYn names, and
# since Windows reassigns those names, the wrong monitor ends up blacked out.
# (Relevant here: the Parsec virtual display adapter can come and go.)
# ----------------------------------------------------------------------------
$script:NeedsRebuild = $false
$onDisplayChange = { $script:NeedsRebuild = $true }
[Microsoft.Win32.SystemEvents]::add_DisplaySettingsChanged($onDisplayChange)

function Rebuild-Overlays {
    foreach ($f in $controller.Overlays) {
        try { $f.Close(); $f.Dispose() } catch {}
    }
    $controller.Overlays       = New-Overlays
    $controller.ActiveScreen   = $null
    $controller.Candidate      = $null
    $controller.CandidateSince = [DateTime]::MinValue
}

# Poll ~6x/sec. Cheap, and instant enough to feel responsive.
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $PollMs
$timer.Add_Tick({
    # The display-change event arrives on a background thread; do the rebuild
    # here on the UI thread instead, where creating windows is safe.
    if ($script:NeedsRebuild) {
        $script:NeedsRebuild = $false
        Rebuild-Overlays
    }
    Update-Overlays
})
$timer.Start()

# ----------------------------------------------------------------------------
# Global hotkeys via RegisterHotKey + a WndProc subclass to catch WM_HOTKEY.
# ----------------------------------------------------------------------------
Add-Type -Namespace Win -Name Hotkey -MemberDefinition @"
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool RegisterHotKey(System.IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool UnregisterHotKey(System.IntPtr hWnd, int id);
"@

$MOD_ALT     = 0x0001
$MOD_CONTROL = 0x0002
$WM_HOTKEY   = 0x0312
$ID_TOGGLE = 1; $ID_UP = 2; $ID_DOWN = 3; $ID_QUIT = 4

Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Windows.Forms;
public class HotkeyWindow : NativeWindow {
    public event Action<Message> OnHotkey;
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312 && OnHotkey != null) OnHotkey(m);
        base.WndProc(ref m);
    }
}
"@ -IgnoreWarnings

function Stop-Dimmer {
    $timer.Stop()
    try { [Microsoft.Win32.SystemEvents]::remove_DisplaySettingsChanged($onDisplayChange) } catch {}
    foreach ($id in @($ID_TOGGLE,$ID_UP,$ID_DOWN,$ID_QUIT)) {
        [Win.Hotkey]::UnregisterHotKey($controller.Handle, $id) | Out-Null
    }
    if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() }
    foreach ($f in $controller.Overlays) { $f.Close() }
    $controller.Close()
    [System.Windows.Forms.Application]::Exit()
}

function Set-DimLevel([double]$level) {
    $controller.DimLevel = [Math]::Max(0.05, [Math]::Min(1.0, $level))
    Update-Overlays
    Update-TrayText
}

function Toggle-Dimmer {
    $controller.IsActive = -not $controller.IsActive
    Update-Overlays
    Update-TrayText
}

# ----------------------------------------------------------------------------
# Tray icon: the only visible trace of the program. No console, no window.
# ----------------------------------------------------------------------------
function New-TrayIcon {
    # Draw a simple half-moon-ish icon: a light circle with a dark disc cut in.
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.FillEllipse([System.Drawing.Brushes]::Gainsboro, 2, 2, 28, 28)
    $g.FillEllipse([System.Drawing.Brushes]::Black, 10, 2, 28, 28)
    $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $script:TrayToggleItem = $menu.Items.Add('Dimming on')
    $script:TrayToggleItem.add_Click({ Toggle-Dimmer })
    [void]$menu.Items.Add('Dim more    (Ctrl+Alt+Up)').add_Click({ Set-DimLevel ($controller.DimLevel + $OpacityStep) })
    [void]$menu.Items.Add('Dim less    (Ctrl+Alt+Down)').add_Click({ Set-DimLevel ($controller.DimLevel - $OpacityStep) })
    [void]$menu.Items.Add('-')
    [void]$menu.Items.Add('Quit    (Ctrl+Alt+Q)').add_Click({ Stop-Dimmer })

    $tray = New-Object System.Windows.Forms.NotifyIcon
    $tray.Icon             = $icon
    $tray.ContextMenuStrip = $menu
    $tray.Visible          = $true
    $tray.add_MouseClick({ param($s,$e) if ($e.Button -eq 'Left') { Toggle-Dimmer } })
    return $tray
}

function Update-TrayText {
    if (-not $script:Tray) { return }
    $state = if ($controller.IsActive) { 'on' } else { 'off' }
    $pct   = [int]($controller.DimLevel * 100)
    # NotifyIcon.Text is capped at 63 chars.
    $script:Tray.Text = "Monitor Dimmer: $state, $pct%  (Ctrl+Alt+F toggles)"
    $script:TrayToggleItem.Text    = if ($controller.IsActive) { 'Dimming on  (click to turn off)' } else { 'Dimming off  (click to turn on)' }
    $script:TrayToggleItem.Checked = $controller.IsActive
}

$hotWin = New-Object HotkeyWindow
$hotWin.add_OnHotkey({
    param($m)
    switch ([int]$m.WParam) {
        $ID_TOGGLE { Toggle-Dimmer }
        $ID_UP     { Set-DimLevel ($controller.DimLevel + $OpacityStep) }
        $ID_DOWN   { Set-DimLevel ($controller.DimLevel - $OpacityStep) }
        $ID_QUIT   { Stop-Dimmer }
    }
})

$controller.Add_HandleCreated({
    $h = $controller.Handle
    $hotWin.AssignHandle($h)
    [Win.Hotkey]::RegisterHotKey($h, $ID_TOGGLE, ($MOD_CONTROL -bor $MOD_ALT), [int][System.Windows.Forms.Keys]::F)    | Out-Null
    [Win.Hotkey]::RegisterHotKey($h, $ID_UP,     ($MOD_CONTROL -bor $MOD_ALT), [int][System.Windows.Forms.Keys]::Up)   | Out-Null
    [Win.Hotkey]::RegisterHotKey($h, $ID_DOWN,   ($MOD_CONTROL -bor $MOD_ALT), [int][System.Windows.Forms.Keys]::Down) | Out-Null
    [Win.Hotkey]::RegisterHotKey($h, $ID_QUIT,   ($MOD_CONTROL -bor $MOD_ALT), [int][System.Windows.Forms.Keys]::Q)    | Out-Null
})
$controller.Add_FormClosed({
    try { [Microsoft.Win32.SystemEvents]::remove_DisplaySettingsChanged($onDisplayChange) } catch {}
    try { $hotWin.ReleaseHandle() } catch {}
})

# Force handle creation so HandleCreated fires and hotkeys register.
$null = $controller.Handle

$script:Tray = New-TrayIcon
Update-Overlays
Update-TrayText
try {
    [System.Windows.Forms.Application]::Run($controller)
} finally {
    if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() }
}
