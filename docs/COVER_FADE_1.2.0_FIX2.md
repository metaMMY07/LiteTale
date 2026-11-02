# LiteTale 1.2.0：封面首显渐变修复

2026-11-02。Android 1.2.0+84；iOS 构建号由设备工作流生成。本轮只处理书籍封面过渡，详情页布局和主题文件保持 build83 原样。

## 原因与移植依据

build83 将 ImageStream 的同步解码命中也判作已显示，并在收到图像时提前登记显示记录；预加载、离屏或保活标签中的图片因此可能在真正出现前就跳过动画。200ms 强 ease-out 又使大部分明暗变化集中在前几十毫秒。只有轻书架提供的 BlurHash 底层较容易看见差异。

- Novella 固定提交 `bedd62c5a20aa80e9bf922b33ea12887d991aa8a` 的 `BookCoverImage`：200ms cross-dissolve、底层预览保留到过渡结束、实际 onDisplay 后登记256项显示记录。Expo Image 固定 `expo-image@58.0.16` 的 `ImageTransition.swift` 确认默认 ease-in-out，`skipOnCacheHit=none`；内存解码命中本身不会取消首显过渡。
- Yomiru 正式1.6.0包的主题渐变占位与原图显现已在先前REA录像中确认。封面业务源码未公开、其AOT读取不受支持，不能宣称已经提取私有 CoverImage 的曲线或代码。Android 独立适配同类 OctoImage 公开的500ms foreground fade / easeIn，保留随所选主色生成的占位渐变；这不是对私有参数的反编译结论。

固定来源：

- https://github.com/celia-sh/Novella/blob/bedd62c5a20aa80e9bf922b33ea12887d991aa8a/apps/mobile/src/components/book-cover-image.tsx
- https://github.com/expo/expo/blob/expo-image%4058.0.16/packages/expo-image/ios/ImageTransition.swift
- https://github.com/expo/expo/blob/expo-image%4058.0.16/packages/expo-image/ios/ImageView.swift
- https://pub.dev/documentation/octo_image/2.1.0/octo_image/OctoImage/OctoImage.html
- Yomiru包/REA运行录像、源码公开范围：`docs/research/DETAIL_COVER_RESEARCH_2026-11-02.md`。

## 最终行为

- 封面实际参与绘制后才启动过渡和登记显示记录。已解码但没有显示的封面仍走首显过渡；已经看过的封面再次出现直接显示。离屏预加载不消耗动画，不延迟请求，也不增加网络调用。
- iOS 所有书源共用 Novella 的200ms ease-in-out交叉渐变。有原站/缓存小预览时使用；没有时用本次解码的同一图像，在32×48绘制层上生成模糊底图。底层保持到原图不透明，不等待缩略图编码、也不假装可以在原图未到达时猜出封面。
- Android 的500ms封面显现保留动态主色渐变底，不改全局主题、不改变卡片尺寸，文字与点击入口不被阻塞。此时长用于单张新封面，原站数据/缓存没有人为等待。
- 同步首帧、慢网首帧、六个内置来源和导入规则源采用相同显示语义。发现/书架/历史/本地书籍与下载相关封面全部使用专用组件。阅读插图和全页转圈不改；减少动态效果直接显示。
- 保留原有 source/revision 隔离、显式重试、小预览256项/8MiB、最多2活动且不排队等限制。过期帧和过期绘制回调不能登记另一书源的新图。

## 必要验证

10项针对性检查通过：两平台六来源的同步解码首显、中间态与结束态、Android自选主色、离屏预加载、缓存再次显示、旧帧隔离、减少动态效果，以及此前详情/继续阅读/空字段/窄屏检查。iOS 100ms中间态约50%而非接近完成，Android250ms仍在渐变；两端都不跳动封面框位。

保存两端6来源的5个中间帧，已视觉查看。测试使用自绘样本和Flutter测试字体，不是iOS实体界面或真实站点验收。仅新增/改动封面模块与测试静态分析无问题；下载页沿用的5项既有lint提示保留，无编译错误。不重跑全量与模拟器，用户装机验收。

记录位于 `build/qa/cover-fade-fix2-20261102/`。`unchanged-ui-hashes.json` 对比确认详情页、共用详情布局和主题均与build83一致。安装包摘要与云端结果记录于发布说明。
