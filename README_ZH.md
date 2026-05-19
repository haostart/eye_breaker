# Eye Break（护眼休息）

[English](README.md) | [中文]

一个低打扰的护眼休息遮罩程序，支持 Windows / macOS。托盘运行，按周期弹出全屏遮罩（呼吸圈 / 自定义图片）提醒你休息眼睛。

## 运行平台
- 目标/测试平台：Windows 11 家庭中文版
- 构建工具链：Windows 使用 Visual Studio 2022 + CMake，macOS 使用 Xcode/clang + CMake
- 其他版本：未测试

## 构建与运行
```powershell
cmake -S . -B build
cmake --build build --config MinSizeRel
.\build\MinSizeRel\eye_breaker.exe
```

### macOS
```bash
cmake -S . -B build
cmake --build build
open build/eye_breaker.app
```

## 托盘操作
- 左键单击：显示遮罩（为避免与双击冲突，延迟 250ms）
- 双击：打开设置
- 右键：托盘菜单（设置 / 立即休息 / 重载配置 / 关于 / 退出）

## 配置文件
位置：Windows 与 exe 同目录的 `config.json`；macOS 为 `~/Library/Application Support/eye_breaker/config.json`。
如果 `config.json` 不存在，首次运行会自动生成。

示例：
```json
{
  "language": "en",
  "autostart": false,
  "pause_on_fullscreen": true,
  "play_music": false,
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

说明：
- `language`：`en` 或 `zh`（加载 `assets/lang_en.txt` / `assets/lang_zh.txt`）
- `work_interval_minutes`：设为 `0` 关闭周期触发
- `autostart`：Windows 写入 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`；macOS 使用 LaunchAgents
- `play_music`：设为 `true` 后，休息时播放 `assets/bgm.mp3`
- `visual_mode`：`breathing` / `image` / `image+breathing`
- `image_mode`：`fit` / `fill` / `center`

## 程序图标
程序图标已作为资源嵌入：
- 图标文件：`assets/icon.ico`
- 资源文件：`app.rc` + `resource.h`

## 隐私
不联网、不上传。所有配置仅保存在本地。
