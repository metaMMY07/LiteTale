<div align="center">
  <img src="assets/icon_previews/iris.png" width="144" alt="LiteTale 应用图标">
  <h1>LiteTale</h1>
  <p>基于 Wild 的 Material You Android 轻小说阅读器</p>

[![license](https://img.shields.io/github/license/metaMMY07/LiteTale)](LICENSE)
[![release](https://img.shields.io/github/v/release/metaMMY07/LiteTale)](https://github.com/metaMMY07/LiteTale/releases)
[![downloads](https://img.shields.io/github/downloads/metaMMY07/LiteTale/total)](https://github.com/metaMMY07/LiteTale/releases)
</div>

## Android 正式版 v0.1.24

LiteTale 0.1.24 已发布，提供 ARM64 手机／平板版和 x86_64 模拟器版。本版重点改善文库8的重复加载与切章等待：详情和已读章节可在有效期内复用，阅读时会在后台准备下一章。

[下载 ARM64 手机／平板版 APK](https://github.com/metaMMY07/LiteTale/releases/download/v0.1.24/LiteTale-0.1.24-arm64-v8a.apk) · [下载 x86_64 模拟器版 APK](https://github.com/metaMMY07/LiteTale/releases/download/v0.1.24/LiteTale-0.1.24-x86_64.apk) · [查看 0.1.24 发布说明](https://github.com/metaMMY07/LiteTale/releases/tag/v0.1.24)

文库8网页章节缓存仅在应用进程运行期间保留；首次读取或缓存失效时仍需联网。详细测试结果与版本说明见 [0.1.24 发布记录](docs/releases/0.1.24.md)。

### 功能

- 在哔哩轻小说、文库8、轻书架与轻小说百科之间切换，也可以导入自定义规则书源；各书源的账号、书架和阅读记录分别保存。
- 支持搜索、书籍详情、目录与阅读；增加哔哩轻小说原站读取和验证恢复入口，并持续改进文库8与轻书架的读取稳定性。
- 提供 Material You 配色、多种应用图标配色、平板横屏双页阅读和仿真翻页。
- 分别导入全局界面字体和阅读字体，支持 TTF／OTF；加密章节继续使用书源所需字体，避免乱码。
- 书源导入支持 LiteTale JSON 和 Legado JSON 的部分 CSS／JSON 规则；不执行外部脚本。

APK 使用与既有版本相同的 Android Debug 签名，适合直接安装和从同签名版本升级；目前不用于 Google Play 等商店分发。

## 构建

项目需要 Flutter、Rust 与 Flutter Rust Bridge 对应的构建环境。Windows 本机构建入口：

```powershell
powershell -ExecutionPolicy Bypass -File tools/build_android.ps1
```

Android 构建说明见 [ANDROID.md](ANDROID.md)，版本历史见 [CHANGELOG.md](CHANGELOG.md)。

## 来源与许可

- 本项目基于 [Wild](https://github.com/niuhuan/wild) 修改，Wild 及其衍生代码按 [GNU GPL v3](LICENSE) 发布。
- Windows 应用图标来自 [celia-sh/Novella](https://github.com/celia-sh/Novella)，按 [GNU AGPL v3](LICENSES/AGPL-3.0.txt) 许可使用。
- 内置霞鹜新致宋 Plus 字体按字体文件声明的 [IPA Font License v1.0](LICENSES/IPA.txt) 使用。
- 详细来源和修改范围见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

分发或继续修改本项目时，请保留原作者、上游项目和许可证声明，并按相应许可证提供源代码及字体许可文本。

## 责任声明

1. 本项目仅供学习和研究使用。
2. 本项目不存储小说内容，内容由第三方站点提供。
3. 使用者应自行遵守所在地法律及内容站点的服务条款。
4. 本项目及贡献者不对使用本软件产生的后果承担责任。
