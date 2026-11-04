<div align="center">
  <img src="assets/icon_previews/iris.png" width="144" alt="LiteTale 应用图标">
  <h1>LiteTale</h1>
  <p>基于 Wild 的 Android 与 iOS 轻小说阅读器</p>

[![license](https://img.shields.io/github/license/metaMMY07/LiteTale)](LICENSE)
[![release](https://img.shields.io/badge/release-v1.2.2-blue)](https://github.com/metaMMY07/LiteTale/releases)
[![downloads](https://img.shields.io/github/downloads/metaMMY07/LiteTale/total)](https://github.com/metaMMY07/LiteTale/releases)
</div>

## 最新正式版 LiteTale 1.2.2

[Android 手机／平板 APK](https://github.com/metaMMY07/LiteTale/releases/download/v1.2.2/LiteTale-v1.2.2-android-arm64-v8a.apk) · [Android x86_64 APK](https://github.com/metaMMY07/LiteTale/releases/download/v1.2.2/LiteTale-v1.2.2-android-x86_64.apk) · [iPhone／iPad IPA（未签名）](https://github.com/metaMMY07/LiteTale/releases/download/v1.2.2/LiteTale-v1.2.2-ios-unsigned.ipa) · [更新内容](https://github.com/metaMMY07/LiteTale/releases/tag/v1.2.2)

iOS 安装包需要自行签名后安装。

### 相比 v1.2.0

- 阅读页加入章节进度跳转和浮动工具栏，改进连续滑动翻页及音量键翻页。
- 调整详情页收藏与书评入口，优化阅读菜单外观和深色模式。
- Android 章节目录恢复完整页面，阅读设置支持半屏预览与轻扫展开。

### 界面预览

展示 iOS 与 Android 端的主要界面。

<table>
  <tr>
    <td align="center"><img src="assets/screenshots/ios-1.0.0/01-discover-ios.png" width="230" alt="iOS 文库8发现页"><br>发现</td>
    <td align="center"><img src="assets/screenshots/ios-1.0.0/02-history-ios.png" width="230" alt="iOS 阅读历史页"><br>阅读历史</td>
    <td align="center"><img src="assets/screenshots/ios-1.0.0/03-my-ios.png" width="230" alt="iOS 我的页面"><br>我的</td>
  </tr>
  <tr>
    <td align="center"><img src="assets/screenshots/v1.0.0/01-discover.png" width="230" alt="Android 发现首页"><br>发现 · Android</td>
    <td align="center"><img src="assets/screenshots/v1.0.0/02-bookshelf.png" width="230" alt="Android 在线书架"><br>书架 · Android</td>
    <td align="center"><img src="assets/screenshots/v1.0.0/03-my.png" width="230" alt="Android 我的页面"><br>我的 · Android</td>
  </tr>
</table>

### 功能

- 在哔哩轻小说、文库8、轻书架与轻小说百科之间切换，也可以导入自定义规则书源；各书源的账号、书架和阅读记录分别保存。
- 支持 EPUB 2/3 图文书：Android 可在应用内离线阅读并保留常见原书 CSS；iOS 可将原书交给 Apple Books 阅读。
- 支持搜索、书籍详情、目录与阅读；增加哔哩轻小说原站读取和验证恢复入口，并持续改进文库8与轻书架的读取稳定性。
- iOS 使用系统配色和液态玻璃控件；Android 保留原有 Material You 界面。Android 支持平板横屏双页和仿真翻页，iOS 使用普通翻页。
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