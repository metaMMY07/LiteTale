<div align="center">
  <img src="windows/runner/resources/app_icon.png" width="160" alt="novels icon">
  <h1>LiteTale</h1>

[![license](https://img.shields.io/github/license/MMY-SYSU/novels)](LICENSE)
[![release](https://img.shields.io/github/v/release/MMY-SYSU/novels)](https://github.com/MMY-SYSU/novels/releases)
[![downloads](https://img.shields.io/github/downloads/MMY-SYSU/novels/total)](https://github.com/MMY-SYSU/novels/releases)
</div>

`LiteTale` 是基于 [niuhuan/wild](https://github.com/niuhuan/wild) 的 Android 轻小说阅读器，保留原项目及贡献者的来源和许可。Android 使用 Material You 界面。

## 当前版本

版本：`0.0.18`（Android 正式版）

- 首次打开进入游客首页，在“设置 → 书源与账号”选择文库8或轻书架，再登录对应账号。
- 一次展示一个书源，保留各自登录状态及上次选择；搜索、书架和阅读历史按书源隔离。
- 轻书架书籍、目录、正文与插图使用现有原生页面；其专用 WOFF2 字体经 Rust 转为 TTF 后加载。
- 轻书架收藏暂存本机，云书架同步和授权离线下载未接入；账号权限仍由书源服务决定。
- 保留插图分页、搜索提交修复，以及壁纸取色和六种可选主题色。

Windows 本机构建入口：`powershell -ExecutionPolicy Bypass -File tools/build_android.ps1`。
当前主工程位于 `D:\Projects\LiteTale`。交接及验证边界见 [Luna 交接](docs/LUNA_HANDOFF_0.0.18.md)。

## 旧版记录：v0.0.15

- 接入轻书架近期录入，书库、个人书架和详情统一界面样式
- 修复全屏推荐页右侧空列，优化各页面封面布局与缩放

- 修复搜索请求返回 `403 Forbidden` 的问题
- 修复书架页面一直加载，并增加 Cloudflare WebView 回退
- 修复正文插图无法显示及旧章节缓存不刷新的问题
- 全局界面和阅读正文使用霞鹜新致宋字体
- Windows 应用名称改为 `novels`，并更换应用图标

Windows 成品请从 [Releases](https://github.com/MMY-SYSU/novels/releases) 下载。

## v0.0.15 界面与书源优化

推荐页新增轻书架近期录入的公开书目，参考 Novella 所用的 `api.lightnovel.life` 接口。匿名接口仅提供近期六本；更多书目、详情及阅读会在应用内打开轻书架网站，并按站点要求登录。文库8的搜索、书架和阅读方式不变，两站账号不互通。

内嵌轻书架的书库、个人书架和详情页跟随 novels 的浅色/深色主题及界面字体，书目按窗口宽度自动排布。只调整显示样式，不改动账号、已入库书目和网站的正文阅读设置；外部浏览器仍使用原站界面。

推荐卡片按窗口宽度排列；新书源独立加载并使用短期缓存，不影响原推荐页。

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
