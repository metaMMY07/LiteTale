# 本地 EPUB：参考研究与 REA 拆解

2026-10-18。用户选择沿用 LiteTale 现有阅读器、自选字体、横屏双页与仿真翻页。

## 参考范围与取舍

| 项目 | 核验来源 | 参考内容 | 本轮取舍 |
| --- | --- | --- | --- |
| Anx Reader 1.14.0 | [正式发布](https://github.com/Anxcye/anx-reader/releases/tag/v1.14.0)、[固定源码](https://github.com/Anxcye/anx-reader/tree/356b7183e8463e7c60d84a72502d0055e55a19fd) | Flutter 应用的导入、私有文件、封面、内容摘要去重；APK 中实际携带 foliate-js | 采用独立书库、摘要身份、导入和阅读分离的设计；不引入第二个阅读界面 |
| Readium Kotlin Toolkit 3.4.0 | [EpubParser](https://github.com/readium/kotlin-toolkit/blob/3.4.0/readium/streamer/src/main/java/org/readium/r2/streamer/parser/epub/EpubParser.kt) | container → OPF → manifest/spine、EPUB 3 nav → EPUB 2 NCX、格式错误区分 | 独立 Dart 实现相同的格式顺序；不迁入 Android 专用 Kotlin 引擎 |
| foliate-js | [项目文档](https://github.com/johnfactotum/foliate-js)与 APK 内模块 | 解析和排版接口分离、资源生命周期、按章装载、不同版式 | 使用现有原生排版与页面缓存，不承诺保留任意 CSS、音视频和交互脚本 |
| KOReader | [项目 README](https://github.com/koreader/koreader) | 外置字体、重排版和文档阅读体验 | 作为行为参考，不复制其 AGPL 引擎或整体界面 |

Anx 固定版本源码中的 `lib/service/book.dart` 与 `lib/service/md5_service.dart` 显示：书文件保存到私有路径，记录封面和阅读位置，并按原文件 MD5 判断重复。本项目独立实现采用 SHA-256；原文件不删除，仅保存阅读所需的规范化章节与图片，避免再存一份压缩包。

格式核对以 [W3C EPUB 3.3](https://www.w3.org/TR/epub-33/) 为依据。正文顺序来自 spine，不能直接把 ZIP 文件名或目录列表排序当作章节顺序。

## 本机 REA 的实际使用

先阅读 `E:/rea/使用说明.md` 与 `reverse-engineer-anything/SKILL.md`，沿用已部署 REA 6.5.0，没有修改 MCP 配置或安装其他分析器。

分析对象：官方下载 `Anx-Reader-android-1.14.0-arm64-v8a.apk`，27,520,363 字节，SHA-256：

`ac17738ddd11c2b1834494b1a31d494384fcabefa8501c9587ab63fef20b1eb4`

1. `open_binary` 打开真实 APK；`inspect_artifact(detail: summary)` 静态核对 2,760 个条目，无完整性冲突。完整库存证据 `ev_263ecdbfd25cf6924b6481ec70c798a508a7d2106f1c7e4a6428faf6e4ed112a`。
2. `inspect_analysis_view` 精确定位 APK 中 `assets/flutter_assets/assets/foliate-js/src/{epub.js,epubcfi.js,book.js,progress.js}`，条目均有已验证哈希。投影证据 `ev_db08566ec0e0fc8797f7e95416bc3986f4bac46126943308f3ef66c9bbbe52df`。
3. 仅提取 APK 的普通 JS/HTML 文件，不运行安装包或构建脚本。提取账本为 `build/research/epub/anx-assets.json`。
4. 对打包的 `epub.js` 与直接依赖 `epubcfi.js` 使用 `analyze_javascript_application(detail: summary)`：61,399 字节、9,665 个 AST 节点、两个文件均解析成功。父证据 `ev_c8cab3c946b5bcd326176786801c264c5d7233034f7ba16eeeab9134bfcc771f`。这两个文件是从发布 APK 提取的字节，不是用当前开发分支冒充发布实现。
5. 模块源码核对 `epub.js:920` 起的初始化路径：读取 container rootfile、选择 OPF、建立资源和 spine sections、EPUB 3 导航优先、NCX 回退；每一 section 暴露 load/unload，资源加载与排版分离。资源和元数据并非按 ZIP 字母顺序读取。
6. 导出 `build/research/epub/rea-epub-evidence.json` 后关闭分析会话。

覆盖边界：这是发布产物的静态分析；没有运行 Anx APK，也没有反编译 Flutter AOT。REA 的通用 JS 关系图有动态属性等未知，字符串特征追踪未命中，不能据此声称目标没有该功能。上面的格式路径由发布模块源码逐项核对，运行验证针对 LiteTale 自己的实现进行。

## 落地设计

- 在线书源选择保持不变，书架各状态都能打开独立的本地书籍页；导入、阅读不依赖登录和网络。
- 文件内容 SHA-256 作为 `epub:<digest>` 稳定身份，重命名不会重复导入，阅读记录与在线同名书隔离。
- 导入在 isolate 中校验并转换一次，私有目录按书保存规范化章节和引用图片；进入章节无需重复解压整书。
- 目录、封面、正文、图片经过格式校验后才发布成一本可读书，失败或中断的导入不显示为成功。
- 本地图片使用应用自有 `epub-asset:` 标识；图片组件只读取该书登记的私有资源，不把 EPUB 路径当任意文件路径。
- 阅读仍使用原有字体、分页缓存、横屏双页和卷曲渲染。下一章复用已有预取调度，本地章节有小容量缓存与在途请求合并。
- 移除先使书籍代次失效，等待已开始的进度保存结束后删除其历史；文件按已知清单逐项处理，不递归删除目录，不删除用户原始 EPUB。

本轮目标是可重排的 EPUB 2/3 图文书籍，不是完整 EPUB 排版引擎。DRM、固定版式、任意 CSS、音视频和书内脚本不在支持范围，不能以导入成功冒充完整标准兼容性。
