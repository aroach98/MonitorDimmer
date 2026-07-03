# Monitor Dimmer

A free, single-file PowerShell replacement for DisplayFusion's **Monitor Fading** feature.

It dims every monitor with a semi-transparent, click-through overlay and automatically
un-dims whichever monitor holds the currently focused window — so your attention monitor
stays bright while the others fade back.

## Features

- One borderless, topmost, click-through overlay per monitor (the same technique DisplayFusion uses).
- Automatically un-dims the monitor holding the focused window.
- Per-monitor DPI aware, so overlays cover mixed-DPI setups exactly.
- Global hotkeys to toggle, adjust the dim level, and quit.
- No installation, no dependencies — just Windows PowerShell and .NET (built into Windows).

## Usage

Double-click **`Start-MonitorDimmer.bat`**, or run directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File MonitorDimmer.ps1
```

## Default hotkeys

| Hotkey | Action |
| ------ | ------ |
| `Ctrl + Alt + F` | Toggle dimming on/off |
| `Ctrl + Alt + Up` | Dim more (darker) |
| `Ctrl + Alt + Down` | Dim less (lighter) |
| `Ctrl + Alt + Q` | Quit |

## Configuration

Edit the **Settings** block near the top of `MonitorDimmer.ps1`:

| Setting | Default | Meaning |
| ------- | ------- | ------- |
| `$DimLevelStart` | `0.90` | Starting dim, `0.0` (invisible) to `1.0` (fully black) |
| `$DimColor` | `Black` | Any .NET color name (`Black`, `DimGray`, `Navy`, …) |
| `$OpacityStep` | `0.10` | How much Up/Down changes the dim |
| `$StartActive` | `$true` | Start with dimming already on? |

## License

MIT
