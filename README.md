# 键舞 · KeyWoo

**让每一次打字，都有喜欢的键盘声音。**

KeyWoo 是一款本机运行的机械键盘音效软件。选择红轴、青轴、Holy Panda 或 Topre 等实录音色，让笔记本和外接键盘也有清晰、有层次的敲击反馈；空格、回车、退格会使用对应的大键音色。另有麻将、打字机等实录拟音与独立标注的趣味合成音效。

KeyWoo is a local keyboard sound app for macOS and Windows. Give everyday typing the character of recorded mechanical keyboards, with distinct sounds for larger keys and a choice of playful effects.

## 下载与安装

v1.0 发布候选面向 **macOS 14+ / Apple silicon** 与 **Windows 11 / x64**。当前仓库和发布包保持私有；需要接受仓库邀请并登录获授权的 GitHub 账号才能下载。

[下载页面](https://github.com/LeavesLei/KeyWoo/releases) · [安装说明](docs/INSTALL.md) · [v1.0 说明](docs/RELEASE-v1.0.md)

| 平台 | 下载文件 | 使用方式 |
| --- | --- | --- |
| Mac | 标有 `mac-arm64` 的 `.dmg` 或 `.zip` | 将 KeyWoo 拖入「应用程序」 |
| Windows | 标有 `win-x64` 的 `setup.exe` | 按提示安装到当前用户 |
| Windows 便携版 | 标有 `win-x64` 的 `.zip` | 完整解压后运行 `KeyWoo.exe` |

目前 Mac 包使用固定本地签名，尚未取得 Apple Developer ID 公证；Windows 包尚未做 Authenticode 签名。首次打开可能需要系统确认。Windows 构建与自动检查不能替代实体键盘、声卡和桌面体验验收；具体完成状态以该次 Release 说明为准。

## 日常使用

- **24 套音效**：12 套键盘实录、3 套实录拟音、9 套合成音效。点击整张音色卡即可切换和试听。
- **一致的响度**：音色间做整体响度匹配，保留同一键盘大小键的差异。音量可调；输出设有峰值保护。
- **跨应用反馈**：在编辑器、浏览器等应用中打字也能发声。Mac 首次使用需允许「输入监控」。
- **辅助改键**：单键、组合键，以及播放／暂停、上一首、下一首等媒体操作。映射发生在电脑侧；Mac 改键另需「辅助功能」权限。
- **本机统计**：按时间段查看各键次数并导出 CSV，不保存输入文字或按键顺序。
- **简洁界面**：支持中文、英文，以及跟随系统、浅色和深色外观。Mac 另有可选的桌面律动。

音乐模式仍在内部研究，不包含在 v1.0 的公开功能中。品牌和轴体名称用于说明录音来源，不代表相关厂商参与或背书。

外接键盘若在固件内部处理 Fn，单独按 Fn 可能不会向电脑发送事件；KeyWoo 只能对系统实际收到的按键发声和改键。Mac 与 Windows 的键码不同，改键配置分别保存。

## 隐私与声音来源

日常音效、改键和统计不需要账号或网络服务。统计只保存在电脑上，使用分钟级的逐键计数；主动导出的 CSV 由你决定保存和分享。

[隐私说明](docs/PRIVACY.md) · [声音与第三方许可](THIRD-PARTY-NOTICES.md)

## 从源码构建

先还原并核对项目资源：

```sh
python3 scripts/prepare-assets.py
```

macOS 需要 Xcode Command Line Tools 和 Swift：

```sh
./scripts/test.sh
./scripts/build-app.sh
```

本机打包脚本使用显式配置的固定签名身份，不包含签名私钥。Windows 构建需要 .NET 10 SDK，详见 [Windows 开发说明](windows/README.md)。

本仓库保持私有，项目代码未另行授予开源许可。第三方组件和录音按各自的许可分发。
