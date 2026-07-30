# QuietRecorder

QuietRecorder 是一款极简的原生 macOS 后台录屏 Agent。它通过一个全局快捷键录制主显示器、系统声音和 Mac 内置麦克风，没有窗口、Dock 图标或菜单栏项目。

仅支持 Apple Silicon 和 macOS 15+。项目使用 Swift Package Manager、ScreenCaptureKit 和 AVFoundation，不包含第三方依赖，也不需要完整 Xcode。

## 功能

- `Control+Option+Command+R` 全局开始或停止录制。
- 主显示器固定输出 1280x720、约 15 FPS 的 HEVC/H.265 视频。
- 系统声音与 Mac 内置麦克风混合为一条 AAC 96 kbps 音轨。
- 蓝牙耳机只负责播放；QuietRecorder 不启用蓝牙耳机麦克风，也不修改系统默认输入。
- MP4 与 telemetry sidecar 在成功收尾后原子发布，不覆盖已有录像。
- 录制期间没有应用窗口、悬浮控件、Dock 图标或菜单栏项目。

macOS 强制显示的屏幕录制和麦克风隐私指示不属于应用界面，QuietRecorder 不尝试绕过或关闭系统隐私机制。

## 系统要求

- Apple Silicon Mac
- macOS 15 或更高版本
- Apple Command Line Tools，包含 Swift 6
- 一台带内置麦克风的 Mac；找不到内建设备时录制会明确失败并写入日志

## 使用

1. 构建并安装应用，然后从 `/Applications/QuietRecorder.app` 启动一次。
2. 首次使用时，在苹果系统提示中允许麦克风与“录屏与系统录音”。权限改变后退出并重新启动应用。
3. 在任何应用前台时按 `Control+Option+Command+R` 开始录制；再次按下停止。
4. 完成的 MP4、遥测 JSON 和可读日志保存在 `~/Movies/QuietRecorder`。

QuietRecorder 是 `LSUIElement` 后台 Agent，正常运行时看不到可点击的应用界面。可以用以下命令启动：

```sh
open -a /Applications/QuietRecorder.app
```

## 构建

```sh
git clone https://github.com/cf-x/QuietRecorder.git
cd QuietRecorder
Scripts/build-app.sh
Scripts/test.sh
Scripts/install-app.sh
```

`Scripts/install-app.sh` 会先等待正在运行的 QuietRecorder 安全停止，再替换 `/Applications/QuietRecorder.app`。默认使用 ad-hoc 签名；重新构建后，macOS 可能要求通过正常的“隐私与安全性”界面重新确认屏幕录制权限。

默认包标识为 `com.fangchenfang.QuietRecorder`。分发自己的构建时应使用自己的唯一包标识和代码签名身份，并同步更新验收断言。

## 验收

静态、构建和包验收：

```sh
Scripts/test.sh
```

完整真人机验收要求应用已经获得两项苹果权限，并提供运行中的 PID 与至少 58 秒成片：

```sh
Acceptance/run_all.sh /Applications/QuietRecorder.app . PID RECORDING.mp4
```

验收会检查签名、权限说明、`LSUIElement`、零第三方依赖、运行时不可见性、时长、分辨率、帧率、HEVC、单条 AAC 音轨、两路真实音频样本及每小时空间折算。

## 已知限制

- 参数固定在源码中，没有设置页、多显示器选择、摄像头、云同步或自动更新。
- 强制结束进程或断电无法执行安全收尾，可能留下隐藏的 partial 文件；正常停止和 `SIGTERM` 会执行混音与清理。
- 如果其他应用启用蓝牙耳机麦克风，蓝牙播放质量仍可能下降；QuietRecorder 只能保证自己始终选择 Mac 内置麦克风。
- 本项目不会隐藏 macOS 的紫色或橙色隐私指示。使用录屏和录音功能时，请遵守当地法律并取得必要同意。

## 许可证

[MIT](LICENSE) © 2026 cf-x
