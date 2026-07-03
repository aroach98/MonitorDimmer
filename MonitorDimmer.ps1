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

    Run:  powershell -NoProfile -ExecutionPolicy Bypass -Sta -File MonitorDimmer.ps1
    Or just double-click Start-MonitorDimmer.bat
#>

# ----------------------------------------------------------------------------
# Settings you can tweak
# ----------------------------------------------------------------------------
$DimLevelStart = 0.90      # 0.0 = invisible, 1.0 = fully black.
$DimColor      = 'Black'   # Any .NET color name: Black, DimGray, Navy, etc.
$OpacityStep   = 0.10      # How much Up/Down changes the dim.
$StartActive   = $true     # Start with dimming already on?

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
# click-through, plus GetForegroundWindow to know what has focus.
# (We use .NET's Screen.FromHandle to map a window to its monitor, so no
#  monitor-handle P/Invoke is needed.)
# ----------------------------------------------------------------------------
Add-Type -Namespace Win -Name Native -MemberDefinition @"
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern System.IntPtr GetForegroundWindow();

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

# ----------------------------------------------------------------------------
# Build one overlay form per monitor.
# ----------------------------------------------------------------------------
$overlays = @()
foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = 'None'
    $f.StartPosition   = 'Manual'
    $f.ShowInTaskbar   = $false
    $f.TopMost         = $true
    $f.BackColor       = [System.Drawing.Color]::FromName($DimColor)
    $f.Opacity         = $DimLevelStart
    $f.Bounds          = $screen.Bounds
    # Remember which physical monitor this overlay belongs to.
    $f | Add-Member -NotePropertyName ScreenName -NotePropertyValue $screen.DeviceName
    $overlays += $f
}

# Realize handles + make them click-through, then hide until we decide.
foreach ($f in $overlays) {
    $f.Show()
    Make-ClickThrough $f
    $f.Hide()
}

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

function Update-Overlays {
    $fg = [Win.Native]::GetForegroundWindow()
    $activeScreen = [System.Windows.Forms.Screen]::FromHandle($fg)
    foreach ($f in $controller.Overlays) {
        if (-not $controller.IsActive) {
            if ($f.Visible) { $f.Hide() }
            continue
        }
        $f.Opacity = $controller.DimLevel
        # Dim every monitor EXCEPT the one holding the focused window.
        $shouldDim = ($f.ScreenName -ne $activeScreen.DeviceName)
        if ($shouldDim -and -not $f.Visible)     { $f.Show(); Make-ClickThrough $f }
        elseif (-not $shouldDim -and $f.Visible) { $f.Hide() }
    }
}

# Poll ~6x/sec. Cheap, and instant enough to feel responsive.
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 160
$timer.Add_Tick({ Update-Overlays })
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

$hotWin = New-Object HotkeyWindow
$hotWin.add_OnHotkey({
    param($m)
    switch ([int]$m.WParam) {
        $ID_TOGGLE { $controller.IsActive = -not $controller.IsActive; Update-Overlays }
        $ID_UP     { $controller.DimLevel = [Math]::Min(1.0, $controller.DimLevel + $OpacityStep); Update-Overlays }
        $ID_DOWN   { $controller.DimLevel = [Math]::Max(0.05, $controller.DimLevel - $OpacityStep); Update-Overlays }
        $ID_QUIT   {
            $timer.Stop()
            foreach ($id in @($ID_TOGGLE,$ID_UP,$ID_DOWN,$ID_QUIT)) {
                [Win.Hotkey]::UnregisterHotKey($controller.Handle, $id) | Out-Null
            }
            foreach ($f in $controller.Overlays) { $f.Close() }
            $controller.Close()
            [System.Windows.Forms.Application]::Exit()
        }
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
$controller.Add_FormClosed({ try { $hotWin.ReleaseHandle() } catch {} })

# Force handle creation so HandleCreated fires and hotkeys register.
$null = $controller.Handle

Write-Host ""
Write-Host "  Monitor Dimmer is running." -ForegroundColor Green
Write-Host "  Ctrl+Alt+F toggle   Ctrl+Alt+Up/Down dim more/less   Ctrl+Alt+Q quit"
Write-Host ""

Update-Overlays
[System.Windows.Forms.Application]::Run($controller)
