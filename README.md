<div align="center">
  <img src="windows/runner/resources/app_icon.png" width="160" alt="novels icon">
  <h1>novels</h1>

[![license](https://img.shields.io/github/license/MMY-SYSU/novels)](LICENSE)
[![release](https://img.shields.io/github/v/release/MMY-SYSU/novels)](https://github.com/MMY-SYSU/novels/releases)
[![downloads](https://img.shields.io/github/downloads/MMY-SYSU/novels/total)](https://github.com/MMY-SYSU/novels/releases)
</div>

`novels` 是基于 [niuhuan/wild](https://github.com/niuhuan/wild) 源代码开发的轻小说阅读器修改版。感谢 Wild 原作者和所有贡献者提供的开源项目。

## 当前版本

版本：`v0.0.14`

- 修复搜索请求返回 `403 Forbidden` 的问题
- 修复书架页面一直加载，并增加 Cloudflare WebView 回退
- 修复正文插图无法显示及旧章节缓存不刷新的问题
- 全局界面和阅读正文使用霞鹜新致宋字体
- Windows 应用名称改为 `novels`，并更换应用图标

Windows 成品请从 [Releases](https://github.com/MMY-SYSU/novels/releases) 下载。

## 功能

- 小说阅读、章节跳转、阅读进度保存和继续阅读
- 书架分类、多选、移动与删除
- 按书名或作者搜索，并保存搜索历史
- 分类、排行榜、评论、登录和自动签到
- 阅读主题、字号、行高、段落间距、自动滚动等设置

## 构建

项目需要 Flutter、Rust 与 Flutter Rust Bridge 对应的构建环境。

```bash
flutter pub get
flutter build windows --release
```

## 来源与许可

- 本项目基于 [Wild](https://github.com/niuhuan/wild) 修改，Wild 及其衍生代码按 [GNU GPL v3](LICENSE) 发布。
- Windows 应用图标来自 [celia-sh/Novella](https://github.com/celia-sh/Novella)，按其 [GNU AGPL v3](LICENSES/AGPL-3.0.txt) 许可使用。
- 内置霞鹜新致宋 Plus 字体按字体文件声明的 [IPA Font License v1.0](LICENSES/IPA.txt) 使用。
- 详细来源和本版修改范围见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 与 [CHANGELOG.md](CHANGELOG.md)。

分发或继续修改本项目时，请保留原作者、上游项目和许可证声明，并按相应许可证提供源代码及字体许可文本。

## 责任声明

1. 本项目仅供学习和研究使用。
2. 本项目不存储小说内容，内容由第三方站点提供。
3. 使用者应自行遵守所在地法律及内容站点的服务条款。
4. 本项目及贡献者不对使用本软件产生的后果承担责任。
