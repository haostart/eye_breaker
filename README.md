# Eye Break

[English] | [中文](README_ZH.md)

A low-distraction eye-break overlay for Windows. It runs in the system tray and periodically shows a full-screen overlay (breathing ring / image) to remind you to rest your eyes.

## Platform
- Target/tested: Windows 11 Home (Chinese edition)
- Toolchain: Visual Studio 2022 + CMake
- Other Windows versions: not tested

## Build & Run
```powershell
cmake -S . -B build
cmake --build build --config MinSizeRel
.\build\MinSizeRel\eye_breaker.exe
```

## Tray Actions
- Single click: show overlay (250ms delay to avoid double-click conflict)
- Double-click: open settings
- Right-click: tray menu (Settings / Show Now / Reload Config / About / Exit)

## Configuration
Location: `config.json` next to the exe.
If `config.json` does not exist, it is created on first run.

Example:
```json
{
  "language": "en",
  "autostart": false,
  "work_interval_minutes": 20,
  "rest_seconds": 20,
  "fade_ms": 600,
  "fps": 20,
  "message": "Look far and blink",
  "visual_mode": "breathing",
  "image_path": "C:/path/to/image.jpg",
  "image_mode": "fit",
  "image_opacity": 0.35
}
```

Options:
- `language`: `en` or `zh` (loads `assets/lang_en.txt` / `assets/lang_zh.txt`)
- `work_interval_minutes`: set to `0` to disable periodic overlay
- `autostart`: writes `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
- `visual_mode`: `breathing` / `image` / `image+breathing`
- `image_mode`: `fit` / `fill` / `center`

## App Icon
The app icon is embedded via resources:
- Icon file: `assets/icon.ico`
- Resource files: `app.rc` + `resource.h`

## Privacy
No network access and no data uploads. All configuration is local.
