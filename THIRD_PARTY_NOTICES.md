# 第三方来源说明

## Wild

本项目是 [niuhuan/wild](https://github.com/niuhuan/wild) 的修改版本，保留上游 Git 提交历史。原项目及其贡献者的代码按 GNU General Public License v3.0 发布，完整许可见仓库根目录的 [LICENSE](LICENSE)。

本修改版没有声称拥有 Wild 原始代码或上游贡献者作品的著作权。

## Novella 与轻书架

Windows 应用图标取自 [celia-sh/Novella](https://github.com/celia-sh/Novella) 仓库中的 `apps/mobile/assets/icon.png`。该仓库按 GNU Affero General Public License v3.0 发布，许可文本见 [LICENSES/AGPL-3.0.txt](LICENSES/AGPL-3.0.txt)。

推荐页的轻书架近期录入接入参考了 Novella 的 `packages/api-client/src/index.ts` 及 `archive/flutter` 分支中的接口约定。网络客户端使用 Dart WebSocket 独立实现，只调用轻书架开放的匿名 `GetLatestBookList` 接口，不复制 Novella 的页面、社区或账号实现。

书目、封面与网站内容由 [轻书架](https://www.lightnovel.app/) 提供，接口服务位于 `api.lightnovel.life`。完整书库、搜索、详情与阅读仍遵循轻书架的账号及权限要求；应用不绕过这些限制，也不会将文库8账号传递给轻书架。

内嵌网页的视觉适配参考了 [LightNovelShelf/Web](https://github.com/LightNovelShelf/Web) 公开的组件结构（AGPL-3.0），在本地添加独立样式，不复制其账号、书架或正文业务实现。原站导航、来源标识、账号权限及阅读设置保留不变。

## 字体

本项目打包了 `LXGWNeoZhiSongPlus.ttf`（霞鹜新致宋 Plus）。字体元数据显示：`Copyright (c) 2023-2026 LXGW; Information-technology Promotion Agency, Japan (IPA), 2003-2019.`，并要求使用者接受 IPA Font License v1.0。完整许可见 [LICENSES/IPA.txt](LICENSES/IPA.txt)。
