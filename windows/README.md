# 键舞 / KeyWoo 1.0 — Windows

原生 WPF 键盘音效版。提供真实键盘录音、实录拟音与趣味合成音效，支持 0–1600% 音量、全局物理键反馈、逐键次数统计、软件改键、组合快捷键、媒体控制、中英文与系统/浅色/深色外观。

## 运行

下载后运行 `KeyWoo-1.0.0-win-x64-setup.exe`，安装到当前用户，无需管理员权限。开始菜单中可以打开 KeyWoo；安装末页可选立即运行，也可勾选桌面快捷方式。卸载可通过 Windows「设置 → 应用」，保留个人设置和统计。升级前请从 KeyWoo 托盘菜单退出。应用未做 Authenticode 签名，Windows 可能显示未知发布者提醒。

便携版可以将 `KeyWoo-1.0.0-win-x64.zip` **完整解压**到一个文件夹后打开 `KeyWoo.exe`。两种包均自包含，无需另装 .NET；`Assets` 和 `Licenses` 文件夹应留在程序旁边。目标为 Windows 11 x64。没有发布 ARM64 包，也没有声称在 Windows 10 或实体 Windows 声卡/键盘上完成测试。

单实例运行。关闭窗口后保留托盘图标；托盘菜单可打开、暂停或退出。全局暂停同时暂停声音、统计和改键。锁屏时释放映射输出并暂停，解锁后恢复此前状态。记录物理扫描码的分钟级次数，不保存文字、按键顺序、窗口标题或应用名。

数据保存在 `%LOCALAPPDATA%\KeyWoo\`。统计支持本地日期和时间范围、逐键表格与 CSV；不完整分钟向外取整，结束时间不含。CSV 为汇总数据。配置标记为 `platform: windows`，使用 Windows 虚拟键/扫描码，**不能直接导入 macOS Quartz 配置**。

## 按键映射

映射默认关闭。到“按键映射”选择来源键和目标键，可分别加 Ctrl/Alt/Shift/Win 组合，添加后再启用。两边均可选播放/暂停、上一首、下一首、音量、F1–F24、数字小键盘、导航、浏览器和系统键。普通单键映射保留按住、重复及松开的行为。组合、媒体、浏览器和启动应用动作每次按压触发一次。Windows 的 Pause 键只发出按下事件，映射为一次完整轻按。统计与音效仍依据原始物理键。

KeyWoo 用 Windows 的低级键盘钩子接收事件，通过 `SendInput` 在当前电脑发出映射结果，设置保存在本机。支持 VIA 的键盘可以通过 VIA 把兼容的映射写入键盘。键盘内部处理的 Fn 层可在系统里表现为媒体键、普通键或组合，也可能没有可供软件捕获的独立 Fn 事件。

开始监听与解锁恢复时，会读取一次 Windows 当前已按住的键：旧按压继续沿用系统原有状态，不补计次数，不在中途改成新映射；真实松开后，下次按压才使用当前规则。按住目标键再启用映射，也不会因释放映射来源而提前释放这个目标键。该快照只含虚拟键状态，不读取文字；Windows 对主回车和小键盘回车共享的启动前状态无法区分来源位置，收到真实事件后才取得扫描码。

At hook startup and unlock, already-held keys retain their existing Windows state. They are not counted or rebound midway through a press; the current mapping starts after their real release. Releasing a remapped source cannot prematurely lift an already-held target. This one-time snapshot reads virtual-key states, never text. Windows shares the pre-start state of main and keypad Enter, so their physical scan identity becomes available only when an actual event arrives.

“添加媒体组合键”创建 Ctrl+Alt+J/K/L（上一首、播放/暂停、下一首）、U/I（音量）、M（静音），随后仍需明确启用映射。使用 AltGr 输入字符时，可选择其他修饰键组合，避免与 Ctrl+Alt 冲突。安全桌面、Ctrl+Alt+Delete、其他系统保留快捷键和更高权限应用不保证可重映射。程序默认以普通用户权限运行，Windows 拒绝合成输入时会停用映射并显示错误。

## 音频与资源

使用固定版本 **NAudio 2.2.1（MIT）** 的共享、事件驱动 WASAPI 输出。样本在启动前验证 SHA-256、解码并缓存。持续运行的混音器最多 24 声部，事件队列有界，每次敲击复用缓存。与 macOS 使用同样的响度校准：只在加载时测量，每套音色应用一个固定增益，保留空格、回车、普通键以及松开声音的相对差异，不给实时发声增加等待。原有音量滑块增益曲线保留，音量超过 200% 时由最终输出的 0.98 软上限控制峰值。滑块前四分之三对应 0–400%，最后四分之一用于额外增益。软件队列耗时仅反映程序内部处理，实际听感还取决于系统和输出设备。

声音使用 Windows 默认输出。系统切换输出后，程序会重新连接；设备出错时最多自动重试三次，仍失败可在设置点「重新连接声音」。重连清理旧声音队列，避免恢复时集中播放之前的按键。此行为已编译检查，真实设备断连与恢复仍需要 Windows 硬件验收。

真实录音、合成缓存、映射和许可证通过项目文件链接同一份 `Sources/KeyDance/Resources/KeyboardSounds/`。键盘与拟音实录从 `manifest.json` 加载，合成音效从 `synthetic-manifest.json` 加载。原作者许可、来源和共享键位说明随 `Assets/KeyboardSounds/THIRD-PARTY-NOTICES.md` 分发，NAudio 和自包含 .NET 运行时的许可位于 `Licenses`。

## 开发与发布

需要 .NET **10 LTS SDK** 和 **Inno Setup 6.3 或更新版本**。统一版本由根目录 `release-version.json` 管理，应用、ZIP 和安装器使用同一个版本。构建不能使用不同的版本参数覆盖它。

```powershell
python scripts/prepare-assets.py
dotnet test windows/KeyWoo.Tests/KeyWoo.Tests.csproj -c Release
./windows/build.ps1
# GitHub Actions 临时 Windows runner：增加实际安装/升级/卸载验证
./windows/build.ps1 -VerifyInstaller
```

`build.ps1` 运行纯 CPU 测试，自包含发布到新的 staging 目录，启动最终 EXE 的 `--verify-assets` 路径验证所有音色实际 PCM 均非静音且互异，再逐文件检查 ZIP 解压内容散列，并编译当前用户安装器。自检路径无需全局键盘钩子、声卡或应用窗口。输出 ZIP、安装 EXE、SHA-256 manifest 和资源自检 JSON 到 `windows/artifacts/`。包内含用户说明、隐私说明、发布说明、声音来源和依赖许可。

GitHub Actions 使用 `-VerifyInstaller`：在临时 Windows runner 上安装到独立路径，检查开始菜单与当前用户卸载注册，重复安装验证升级，运行安装后的资源自检，再卸载并检查设置和统计未被删除。验证脚本拒绝在已有 KeyWoo 配置/安装的环境运行，也拒绝直接在非 GitHub Actions 的个人电脑上执行。CI runner 不等于实体声卡或键盘验收。

macOS 可运行跨平台核心测试、编译和生成 Windows x64 自包含包，不能执行 Windows 安装器和最终 EXE。当前 Windows 包包括声音、单键/组合/媒体改键、计数、中英文和外观；macOS 的多方案/软件键位组和桌面律动暂未移植。最终桌面界面、键盘钩子、媒体控制和 WASAPI 播放仍需在 Windows 实际硬件运行验证。当前包未做 Authenticode 签名。

## 实现依据

- [.NET 支持周期](https://dotnet.microsoft.com/en-us/platform/support/policy/dotnet-core)
- [WPF 官方概览](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/overview)
- [LowLevelKeyboardProc：独立消息线程与超时限制](https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelkeyboardproc)
- [SendInput：注入标记、修饰键状态和权限边界](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput)
- [Win32 虚拟键表](https://learn.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes)
- [PowerToys Keyboard Manager](https://learn.microsoft.com/en-us/windows/powertoys/keyboard-manager)
- [VIA 键码及键盘配置](https://www.caniusevia.com/docs/configuring_qmk/)
- [NAudio WasapiOut](https://github.com/naudio/NAudio/blob/v2.2.1/NAudio.Wasapi/WasapiOut.cs)
- [.NET 自包含与单文件发布](https://learn.microsoft.com/en-us/dotnet/core/deploying/single-file/overview)
