# 隐私说明 / Privacy

适用范围：KeyWoo v1.0 的键盘音效、改键、统计和桌面反馈功能。

## 处理什么

KeyWoo 接收系统交给应用的物理键码、按下／松开状态和修饰键状态，用于发声、改键和统计。它不读取按键对应的文字、不保存逐次按键顺序，也不记录其他应用的名称、窗口标题或窗口内容。

统计文件只保存**每分钟、每个键的次数**。长按产生的系统重复输入不累计为多次物理按压。声卡播放与按住状态保留在运行内存中，退出时释放。

改键配置保存你设置的规则与方案名称；外观、音色、音量等偏好也保存在本机。试听区由你输入的内容只在当前界面使用，不写入统计文件或作为模型提示词。

## 网络与权限

日常使用无需登录，不上传按键、统计或偏好，不依赖云端音乐模型。点击录音来源等外部链接会通过系统浏览器打开对应网站，该网站适用自己的隐私政策。下载与更新文件时，GitHub 和操作系统可能按各自规则处理请求和安全检查。

Mac「输入监控」用于跨应用音效和统计，「辅助功能」用于你启用的改键。两者由用户在系统设置中决定。系统安全输入、锁屏或其他受保护场景可能限制事件，应用不承诺在这些场景持续工作。Windows 使用当前桌面的键盘事件；系统保护桌面和更高权限窗口有额外限制。


「跟随电脑声音」由你单独开启，用于让底部泛光随正在播放的声音变化。音频只在本机即时分析，不保存音频文件、不上传。Mac 使用系统音频捕获权限，并排除 KeyWoo 自己的声音；该功能需要 macOS 14.2 或更新。Windows 分析当前输出设备的混音，其中可能包含 KeyWoo 的键盘音效。关闭该选项、暂停或退出时停止分析。

## 数据位置与删除

| 平台 | 数据位置 |
| --- | --- |
| Mac 统计与改键 | `~/Library/Application Support/KeyDance/` |
| Mac 偏好设置 | macOS UserDefaults，域 `app.keydance.mac` |
| Windows 统计与设置 | `%LOCALAPPDATA%\KeyWoo\` |

Mac 保留旧内部目录名 `KeyDance` 是为了兼容已有数据。统计可手动导出 CSV；导出的文件由你选择保存位置，KeyWoo 不自动分享。

卸载程序不会作为清除个人数据的保证。若要清除统计或规则，先完全退出应用，备份需要保留的文件，再删除上述对应数据。删除统计不可恢复；重新运行后会创建新的数据文件。

## English

KeyWoo processes physical key identifiers and press/release/modifier states to play sounds, apply your mappings and count presses. It does not read typed text or save an ordered key-event history, application names, window titles or window contents.

Statistics are stored locally as per-key totals in one-minute buckets. Settings and user-created mappings remain on the device. Routine use requires no account and uploads no typing data. Source links open in your browser; GitHub downloads and operating-system security checks are governed by their own policies.

On macOS, Input Monitoring enables feedback across applications, while Accessibility is separately used for remapping. OS-protected input contexts may limit operation. On Windows, protected desktops and higher-privilege applications also impose limits.


Follow computer audio is a separate opt-in for the bottom glow. Audio is analyzed live on your device without saving audio files or uploading it. On macOS 14.2 or later, it uses system audio capture permission and excludes KeyWoo itself. Windows analyzes the current output device mix, which can include KeyWoo keyboard sounds. Analysis stops when the option is turned off, KeyWoo is paused, or the app quits.

Data locations are listed above. Quit KeyWoo before removing local data. CSV files are exported only when requested and are never automatically shared.
