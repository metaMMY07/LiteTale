# 本地 EPUB 整合与验收

2026-10-18，LiteTale `0.1.25+67`。用户选择沿用现有阅读器：自选字体、平板横屏双页和仿真翻页。

## 使用方式

书架右上角“本地书籍” → “导入 EPUB” → Android 系统文件选择器。导入后点击封面进入原有详情与目录，选择章节阅读。“历史”中可切换“本地 EPUB”。书籍卡片右下角菜单可查看信息或移除；移除会清理这本书的本机阅读记录，保留用户原文件。

支持 EPUB 2 / 3 的流式图文书籍，单文件最大 128 MB。保留章节顺序、标题、段落、基本列表、注音文字及常见位图；EPUB 3 nav 与 EPUB 2 NCX 均可读取。使用 LiteTale 的字体、纸张和排版，不完整还原原书 CSS。DRM、固定版式、ZIP64、音视频和交互脚本不在本轮支持范围；任意矢量 SVG 不保证还原，含位图的 SVG 封面包装可以解析。遇到不支持内容时提示或记录警告，不显示虚假导入成功。

## 研究与 REA

先研究 Anx Reader、Readium Kotlin Toolkit、foliate-js 和 KOReader；对 Anx Reader 1.14.0 正式 APK 使用本机 REA 核对资产库存及实际打包的 EPUB 解析模块。版本、哈希、证据编号、许可证取舍与静态分析边界见 [研究记录](RESEARCH.md)。没有复制整个外部阅读器或引入另一套 WebView 排版界面。

## 实现与稳定性

- `epub_parser.dart` 在解压前检查 ZIP 目录、路径和声明大小，实际解压也有限额；校验 CRC，拒绝越界、符号链接、重复/不安全路径与加密 ZIP。XML、章节、图片、总展开量及标记复杂度有独立上限。不执行书内脚本，不获取外部网络资源。
- container → OPF → manifest/spine 决定阅读顺序；nav 优先、NCX 回退，同文件目录锚点可分章，Unicode 与百分编码路径可解析。不是按 ZIP 文件名排序。
- `LocalEpubLibrary` 使用原文件 SHA-256 作为 `epub:<digest>` 身份。导入后台转换一次，暂存完成后原子发布私有规范化章节和图片；不再额外保存原 ZIP。默认真实 isolate 路径已测试，传入的是可发送数据，避免闭包意外捕获 Future。
- 启动只读清单，章节直接读本地规范化文件。章节缓存 12 项/4 MiB，图片字节缓存 6 项/8 MiB，均有 TTL 和在途合并；本地下一章预取复用现有调度器。
- 本地书是独立适配器，不进入在线书源列表，不改当前在线书源。封面、目录、正文和历史使用稳定本地 ID，与在线同名小说隔离。不依赖登录或系统文件选择器临时 URI。
- 移除先推进书籍代数，再等待正在落盘的进度写入结束并删除历史，避免旧异步结果使书籍/历史复活。定向清理这本书的排版和读取缓存；原 EPUB 保留。
- 设备测试发现原生仿真翻页可能先缓存空白插图再移除 Flutter 页面。新增每页 `ReaderRasterReadiness`，由 `Image.frameBuilder` 在实际首帧绘制时解除等待；失败页也解除等待。多张图全部就绪才截图，异步 PNG 回读前后检查资源修订号和页面代数。没有固定延时或额外重复解码；原生翻页几何与空白不透明背面保持原实现。

## 自动化与真实文件

最终全量 `flutter test --no-pub`：552 通过、8 可选跳过。补充配置本机 Edge/Playwright，单独运行 CAPTCHA 与文档读取回归：7 通过，其中 2 项是全量时跳过的浏览器夹具。因此去重后为 **554 通过、6 项可选联网测试未执行**。24 个相关 analyze 目标无问题，`git diff --check` 无空白错误。没有用在线夹具冒充书源恢复。

EPUB 专项包括 38 项解析、15 项私有书库、4 项适配/UI、5 项插图栅格就绪测试，以及进度清理屏障和定向排版缓存回归。覆盖 EPUB 2/3、目录/锚点、段落/图片、混合编码路径、损坏包、资源限额、默认 isolate、去重、重启、删除再导入、迟到读取与异步图片首帧/错误。

额外使用 [Project Gutenberg 的 Alice EPUB 3 图片版](https://www.gutenberg.org/ebooks/11)：189,249 字节，SHA-256 `4f81245d31380ac1d6eafb9a321e3691369bc70985736ae4bccf849a4f784036`。真实默认 isolate 导入、全部章节读取、私有书库重开与适配器测试通过；19 章、1 张图片、162,254 字符、无警告。本机桌面测得导入 604 ms、全部读取及重开 113 ms，不能作为 Android/120 Hz 性能结论。该书未打包进应用，未添加为在线书源。

日志保留在 `build/epub-local/`：`all-tests-final.log`、`browser-regression-final.log`、`analyze-final.log`、`real-sample.log`、`build-final.log` 与 `apk-verification-final.log`。

## Android 设备验收

使用 API 35 x86_64 QA 模拟器 `emulator-5554`，保留应用数据覆盖安装。最终安装包回读 SHA-256 与交付 x64 APK 完全一致，首次安装时间仍为 `2026-09-27 14:47:16`。凭据、Cookie、账号 DOM 不导出。实际检查保存在 [checks.json](android/checks.json) 与 [安装核对](android/installed-package.json)。

已实际操作系统文件选择器导入自编 EPUB 2/3（中文/空格路径、NCX/nav、SVG 包装封面、正文位图）；取消、重复、损坏文件和阅读入口均正常。移走原文件后重启，私有书库仍能打开；移除一本书后其本地历史消失、另一书保留，原文件仍在，重启后可重新导入。

导入用户提供的 `YanZhenQingDuoBaoTaBei-2.ttf` 后，本地 EPUB 正文实际呈现书法字体；恢复默认宋体后，正文恢复宋体，全局界面字体保持原值。普通翻页、阅读进度重开均正常。

最终 APK 开启仿真翻页，在飞行模式并关闭 Wi-Fi/蜂窝数据、确认无默认网络后，强制结束并重启应用：本地书的双页正文与插图均正常。竖屏单页、图片页、旋回横屏双页及锚点保留通过。原生翻页截图显示图片参与翻页、背面空白且不透明；上/中/下手势捕获仅作回归观察，不据模拟器宣称实体设备手感或 120 fps 达标。

主要截图：

- [私有书库目录](android/04-private-copy-catalog.png)
- [自选阅读字体](android/11-imported-reader-font.png)
- [断网冷启动 + 仿真翻页插图](android/14-offline-cold-curl-image.png)
- [竖屏图片页](android/16-portrait-illustration.png)
- [旋回横屏双页](android/17-landscape-anchor-restored.png)
- [原生翻页中的图片与空白背面](android/18-curl-middle.png)

测试结束恢复 AVD 飞行模式、Wi-Fi、蜂窝数据和横屏视口；仿书翻页恢复原开启状态，阅读字体恢复原默认状态。首次 QA 脚本过早检查异步蜂窝恢复，已补等待并重新执行，应用功能测试不受影响。

ARM64 已构建并静态校验，尚未在用户实体平板安装；本轮未生成 IPA。支持范围外的排版、真实大体积复杂书和实体 120 Hz 性能仍需后续设备样本验证。
