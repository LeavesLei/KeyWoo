<p align="center">
  <img src="docs/assets/keywoo-icon.png" width="112" height="112" alt="键舞 Logo">
</p>

<h1 align="center">键舞 · KeyWoo</h1>

<p align="center">给日常打字加上机械键盘的声音。</p>

<p align="center">
  <strong>简体中文</strong> · <a href="README.en.md">English</a>
</p>

<p align="center">
  <a href="https://github.com/LeavesLei/KeyWoo/releases/tag/v1.0.0"><img src="https://img.shields.io/badge/preview-v1.0.0-C15F34?style=flat-square" alt="v1.0.0 预览版"></a>
  <a href="https://github.com/LeavesLei/KeyWoo/releases/download/v1.0.0/KeyWoo-1.0.0-mac-arm64.dmg"><img src="https://img.shields.io/badge/macOS_14%2B-Apple_silicon-334155?style=flat-square" alt="下载 macOS 版"></a>
  <a href="https://github.com/LeavesLei/KeyWoo/releases/download/v1.0.0/KeyWoo-1.0.0-win-x64-setup.exe"><img src="https://img.shields.io/badge/Windows_11-x64-334155?style=flat-square" alt="下载 Windows 版"></a>
</p>

键舞是一款在 Mac 和 Windows 上运行的键盘音效软件。在笔记本或外接键盘上打字，就能听到红轴、青轴、Holy Panda、Topre 等实录音色，也可以试试麻将和打字机。

## 下载与安装

| 平台 | 下载 | 安装 |
| --- | --- | --- |
| **Mac** · macOS 14+，Apple 芯片 | [下载 DMG][mac] | 打开 DMG，把键舞拖入「应用程序」。 |
| **Windows** · Windows 11，x64 | [下载安装程序][win] | 运行安装程序，再从开始菜单打开键舞。 |

ZIP 便携包和校验文件也在发布页。首次打开预览版可能出现系统提示，安装指南中有对应步骤。[v1.0.0 发布页][release] · [安装指南](docs/INSTALL.md)

## 开始使用

1. 打开键舞，在音效页选择一种声音，然后在试听区打字。
2. 调到舒服的音量，再切到平时使用的编辑器或浏览器。Mac 用户可点击 **开启全局体验**，在系统设置中允许「输入监控」。

- **24 套音效**，包括 12 套键盘实录、3 套实录拟音和 9 套合成音效。空格、回车、退格有各自的声音。
- **中英文与浅色、深色外观**，可在设置中切换。
- **改键和统计**，可以设置媒体快捷键、查看各键次数并导出 CSV。日常使用无需登录，统计保存在本机，应用不保存输入文字。

[隐私说明](docs/PRIVACY.md) · [音效来源与第三方许可](THIRD-PARTY-NOTICES.md) · [反馈问题](https://github.com/LeavesLei/KeyWoo/issues)

<details>
<summary>从源码构建</summary>

先运行 `python3 scripts/prepare-assets.py` 还原资源。macOS 可用 `./scripts/test.sh` 运行测试，打包使用 `./scripts/build-app.sh` 和本机配置的固定签名身份。Windows 构建需要 .NET 10 SDK。[Windows 开发说明](windows/README.md)

</details>

[mac]: https://github.com/LeavesLei/KeyWoo/releases/download/v1.0.0/KeyWoo-1.0.0-mac-arm64.dmg
[win]: https://github.com/LeavesLei/KeyWoo/releases/download/v1.0.0/KeyWoo-1.0.0-win-x64-setup.exe
[release]: https://github.com/LeavesLei/KeyWoo/releases/tag/v1.0.0
