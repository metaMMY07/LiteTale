# 第三方来源说明

## LightNovelReader 设置界面

设置的分组、主题与纸张预览、数据操作和统计布局参考 [dmzz-yyhyy/LightNovelReader](https://github.com/dmzz-yyhyy/LightNovelReader) 的 `1.1.0`，固定提交为 `a972c991d5b64db95830d8de77986da8cf456044`，与用户提供的截图对应。参考项目按 Apache License 2.0 发布，许可文本见 [LICENSES/LightNovelReader-Apache-2.0.txt](LICENSES/LightNovelReader-Apache-2.0.txt)。原版权归 LightNovelReader 作者及贡献者。

LiteTale 使用 Flutter 与自己的存储、阅读器、书源和更新接口重新适配；没有将上游的 Kotlin/Room 数据库、`.lnr` 格式、账号、AppCenter 或社区端点迁入。可在 [固定版本源码](https://github.com/dmzz-yyhyy/LightNovelReader/tree/a972c991d5b64db95830d8de77986da8cf456044) 查看对应实现。

## Wild

本项目是 [niuhuan/wild](https://github.com/niuhuan/wild) 的修改版本，保留上游 Git 提交历史。原项目及其贡献者的代码按 GNU General Public License v3.0 发布，完整许可见仓库根目录的 [LICENSE](LICENSE)。

本修改版没有声称拥有 Wild 原始代码或上游贡献者作品的著作权。

## Novella 与轻书架

Windows 应用图标取自 [celia-sh/Novella](https://github.com/celia-sh/Novella) 仓库中的 `apps/mobile/assets/icon.png`。该仓库按 GNU Affero General Public License v3.0 发布，许可文本见 [LICENSES/AGPL-3.0.txt](LICENSES/AGPL-3.0.txt)。

轻书架接入参考了 Novella 的 `archive/flutter` 分支和 LightNovelShelf/Web 公布的接口约定。网络客户端使用 Dart WebSocket 与 HTTP 独立实现；0.0.18 增加原生登录、搜索、目录和阅读适配。登录遵循官方表单的密码 SHA-256 协议。匿名首页仅调用 `GetLatestBookList`，受限接口仍按站点要求登录。

书目、封面与网站内容由 [轻书架](https://www.lightnovel.app/) 提供，接口服务位于 `api.lightnovel.life`。完整书库、搜索、详情与阅读仍遵循轻书架的账号及权限要求；应用不绕过这些限制，也不会将文库8账号传递给轻书架。

内嵌网页的视觉适配参考了 [LightNovelShelf/Web](https://github.com/LightNovelShelf/Web) 公开的组件结构（AGPL-3.0），在本地添加独立样式，不复制其账号、书架或正文业务实现。原站导航、来源标识、账号权限及阅读设置保留不变。

## 字体

本项目打包了 `LXGWNeoZhiSongPlus.ttf`（霞鹜新致宋 Plus）。字体元数据显示：`Copyright (c) 2023-2026 LXGW; Information-technology Promotion Agency, Japan (IPA), 2003-2019.`，并要求使用者接受 IPA Font License v1.0。完整许可见 [LICENSES/IPA.txt](LICENSES/IPA.txt)。

Android 集成测试包含上述字体的少量字符 WOFF2 子集，仅用于验证字体转换，不在常规 APK 入口引用。原始字体和 IPA 许可随源码保留。

轻书架章节字体运行时由书源提供。WOFF2 解码使用 `woofwoof`（MIT）及其 WOFF2/Brotli 依赖；版本固定在 `rust/Cargo.lock`，不是将章节字体作为应用资源分发。

## Material 形状

加载指示器使用 [`material_new_shapes`](https://pub.dev/packages/material_new_shapes) 1.0.0 的 Flutter 多边形与 Morph 几何实现，许可为 MIT；版权归 2025 Agbama Gifted，许可文本见 [LICENSES/material_new_shapes-MIT.txt](LICENSES/material_new_shapes-MIT.txt)。形状顺序参考 AndroidX Material 3 的公开实现，应用中的加载组件由本项目实现。

## PTQBookPageView / PTQFlipper

Android 仿书翻页移植自 [FantasticPornTaiQiang/PTQFlipper](https://github.com/FantasticPornTaiQiang/PTQFlipper) 的 PTQBookPageView，固定源码版本 `e8901310f0653924ee62dfeb9b3f27612d4fe790`。原版权归 2023 MPGA，按 MIT 许可提供；原许可与版本说明随源码保存在 [`android/ptqbookpageview/`](android/ptqbookpageview/)。本项目增加 Flutter 桥接、页面位图缓存，并按用户要求将翻页背面改为无文字的不透明纸张。
