<p align="center">
  <img src="docs/assets/keywoo-icon.png" width="112" height="112" alt="KeyWoo logo">
</p>

<h1 align="center">KeyWoo</h1>

<p align="center">Mechanical keyboard sounds for everyday typing.</p>

<p align="center">
  <a href="README.md">简体中文</a> · <strong>English</strong>
</p>

<p align="center">
  <a href="https://github.com/LeavesLei/KeyWoo/releases/tag/v1.0.0"><img src="https://img.shields.io/badge/preview-v1.0.0-C15F34?style=flat-square" alt="v1.0.0 preview"></a>
  <a href="https://github.com/LeavesLei/KeyWoo/releases/download/v1.0.0/KeyWoo-1.0.0-mac-arm64.dmg"><img src="https://img.shields.io/badge/macOS_14%2B-Apple_silicon-334155?style=flat-square" alt="Download for macOS"></a>
  <a href="https://github.com/LeavesLei/KeyWoo/releases/download/v1.0.0/KeyWoo-1.0.0-win-x64-setup.exe"><img src="https://img.shields.io/badge/Windows_11-x64-334155?style=flat-square" alt="Download for Windows"></a>
</p>

KeyWoo plays keyboard sounds as you type on a Mac or Windows PC. Give your laptop or external keyboard the sound of Cherry Red, Cherry Blue, Holy Panda, or Topre switches, or try mahjong tiles and a typewriter.

## Download and install

| Platform | Download | Install |
| --- | --- | --- |
| **Mac** · macOS 14+, Apple silicon | [Download DMG][mac] | Open the DMG and drag KeyWoo into Applications. |
| **Windows** · Windows 11, x64 | [Download installer][win] | Run the installer, then open KeyWoo from the Start menu. |

ZIP packages and checksums are on the release page. Your system may show a security prompt the first time you open this preview. [v1.0.0 release][release] · [Installation guide](docs/INSTALL.en.md)

## Get started

1. Open KeyWoo, pick a sound, and type in the practice area.
2. Set a comfortable volume, then switch to your editor or browser. On Mac, click **Enable across apps** and grant **Input Monitoring** in System Settings.

- **24 sound sets**, including 12 keyboard recordings, 3 recorded effects, and 9 synthesized effects. Space, Enter, and Backspace have distinct sounds.
- **English and Simplified Chinese**, with light and dark appearance options.
- **Remapping and statistics** let you set media shortcuts, see key counts, and export CSV. KeyWoo works without an account, keeps statistics on your device, and does not save typed text.

[Privacy](docs/PRIVACY.md#english) · [Sound credits and third-party licenses](THIRD-PARTY-NOTICES.md) · [Report an issue](https://github.com/LeavesLei/KeyWoo/issues)

<details>
<summary>Build from source</summary>

Run `python3 scripts/prepare-assets.py` to restore the assets. On macOS, use `./scripts/test.sh` to run tests and `./scripts/build-app.sh` to package with your configured local signing identity. Windows builds require the .NET 10 SDK. [Windows build guide](windows/README.md)

</details>

[mac]: https://github.com/LeavesLei/KeyWoo/releases/download/v1.0.0/KeyWoo-1.0.0-mac-arm64.dmg
[win]: https://github.com/LeavesLei/KeyWoo/releases/download/v1.0.0/KeyWoo-1.0.0-win-x64-setup.exe
[release]: https://github.com/LeavesLei/KeyWoo/releases/tag/v1.0.0
