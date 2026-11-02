# LiteTale 1.2.0：覆盖翻页与插图交互

2026-11-02。版本1.2.0+82；iOS设备构建号由云端工作流单独生成。

## 行为

- 普通分页采用参考 Legado-E 的标准覆盖模型：下一页时当前纸张向左离开，上一页时前一张纸返回。点击、拖动与音量键使用同一状态，动画结束才提交进度；短拖取消不改变历史。纸张不透明，背景纹理随纸张移动，动画中不重新排版。
- Android保留原仿真翻页选项；iOS与本地EPUB不恢复仿真翻页。普通翻页预备相邻视图、最多复用三个纸张；本地章节预加载追加不打断正在进行的动画，半幅双页补齐会刷新对应纸张。
- 全部当前内置源（文库8、轻书架、轻小说百科、哔哩、幻梦、SF公开目录）及导入规则源的应用内插图统一支持点击预览、双指/双击缩放、拖动、保存相册与导出原文件。滚动与分页共用；Android原生仿真翻页另传递插图区域，防止点图误翻页。
- 图片读取保留书源归属与原请求头，文库8沿用Rust下载缓存；同图请求合并，压缩原图缓存最多16条/32MiB，单图20MiB、25秒网络预算。预览解码长边最多4096、最多8Mi像素，保存仍使用原始字节，不截屏或重编码GIF。
- Android10+用MediaStore添加自有图片，不索要全部照片/文件管理权限；旧系统及导出用系统文件选择器。iOS按需申请Photos add-only权限，另提供系统分享/导出。取消与成功分开反馈，失败可重试；坏的解码缓存不会使显式重试一直复用旧响应。
- Android完整CSS EPUB仍按原书排版；只为实际插图生成热点，通过同一渲染实例读取离线资源。支持流式页、固定页、SVG内嵌位图，并排除隐藏元素及适屏留白；热点不把整页截图当原图。
- iOS本地EPUB仍交给Apple Books。不能向Books内部注入LiteTale的翻页和图片控件。原书、分类、稳定ID、账号与阅读进度格式不迁移。

## 实现入口

- `lib/widgets/reader_cover_view.dart`、`lib/pages/novel/reader_page.dart`
- `lib/services/reader_images.dart`、`lib/pages/novel/reader_image_viewer.dart`
- `lib/widgets/reader_illustration.dart`、`reader_paper_view.dart`、`cached_image.dart`、滚动reader
- `lib/widgets/page_curl_view.dart` 与Android原生PTQ的图片区域桥接
- `lib/assets/epub_page_engine.js`、`lib/services/epub/epub_css_reader.dart`、`EpubPageChannel.kt`
- `android/app/src/main/kotlin/opensource/wild/ReaderImageChannel.kt`
- `ios/Runner/AppDelegate.swift` 内独立的ReaderImageChannel，以及Info.plist添加照片用途文案

## 验证与边界

新增测试覆盖前后页的绘制关系、完成/取消/移除、关闭动画、预加载追加、原图复用与失败、图片命中、保存结果、EPUB资源与坐标校验和书籍删除失效。

真实Chromium使用项目实际离线JS，通过自编内容测试流式分页、固定版式、SVG内嵌图片，结果与截图在 `output/playwright/reader-images-1.2.0/`。没有真实书源登录或外网资源请求。

全量Flutter测试、分析、原生编译、最终APK/IPA核对结果及源快照见 `docs/releases/1.2.0.md`（封装完成后填写）和 `build/qa/release-1.2.0-20261102/`。旧构建81/23不包含这些功能；没有实体Android/iPhone/iPad装机验证，不宣称全站任意插图均已联网验收或实体120Hz已达标。

## 来源

调研与REA证据索引见 `docs/research/READER_COVER_IMAGES_RESEARCH_2026-11-02.md`。覆盖页模型参考[Legado-E CoverPageDelegate](https://github.com/Luoyacheng/legado-E/blob/624b9b9d21f9f7941c428ba4d6ae209dfb8aa2ed/app/src/main/java/io/legado/app/ui/book/read/page/delegate/CoverPageDelegate.kt)（GPL-3.0，与本工程相同）；Flutter预览参考Anx Reader结构并使用[PhotoView 0.15.0](https://pub.dev/packages/photo_view)（MIT）。没有复制Readest的AGPL实现；失败结果与回退由本工程独立实现。
