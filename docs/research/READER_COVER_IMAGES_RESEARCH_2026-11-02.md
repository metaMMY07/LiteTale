# 覆盖翻页与小说插图预览、缩放、保存：REA 调研与移植方案

日期：2026-11-02  
状态：研究完成；未实现这些新功能，未修改应用代码、依赖或版本，未构建 APK / IPA。  
研究工程：`D:/Projects/LiteTale`。旧环境路径 `C:/Users/30622/Downloads/Novella-main` 不存在。

## 1. 采用的方案与范围

按用户最后补充，以成熟项目的实际体验为准，不再要求逐帧复现最初口述的覆盖方向。

建议采用：

- **翻页：移植 Legado-E 的标准覆盖翻页逻辑。** 页面提前准备，动画只做纸张位移、裁剪和窄阴影；不做两张页面一起横移的推页。
- **插图：借鉴 Anx Reader 的独立全屏 PhotoView 预览器。** 点击进入，双指缩放、双击放大/复位、放大后拖动，提供明确的保存按钮。
- **保存：参考 Readest 的实际结果处理和文件导出回退。** 保存原图，权限拒绝、用户取消、写入失败与成功分别处理。

统一支持全部当前内置书源：**文库8、轻书架、轻小说百科、哔哩轻小说、幻梦轻小说、SF轻小说（公开目录）**；不只做文库8。导入规则源也应走同一图片入口。ESJ 已退出新书源选择，不借本次工作恢复它；旧记录保留。

平台边界：

| 阅读入口 | 覆盖翻页 | 插图预览、缩放、保存 |
| --- | --- | --- |
| Android / iOS 的应用内在线分页阅读 | 新增标准覆盖模式 | 全部书源共用 |
| 在线滚动阅读 | 保留滚动方式 | 共用同一预览器与原图服务 |
| Android 本地 EPUB | 沿用完整 CSS 渲染；普通翻页可采用覆盖模式 | 普通图片可直接接入；CSS 整页渲染需要插图热点数据 |
| iOS 本地 EPUB | 按用户既定要求由 Apple Books 打开 | Books 内部交互由 Books 控制，LiteTale 无法注入；不恢复旧 EPUB 阅读器 |

Android 原有仿真翻页选项独立保留；不恢复 iOS 仿真翻页，也不恢复本地 EPUB 仿真翻页。上一次完成的 EPUB 批量导入、分类和原书 CSS 均保留。

## 2. 研究对象与证据等级

### 2.1 Legado-E：实际 APK 的 REA 分析

- 仓库：[Luoyacheng/legado-E](https://github.com/Luoyacheng/legado-E)
- 版本：[3.26.030717](https://github.com/Luoyacheng/legado-E/releases/tag/3.26.030717)
- 对应源码提交：`624b9b9d21f9f7941c428ba4d6ae209dfb8aa2ed`
- 实际 APK：`D:/Projects/LiteTale/build/qa/legado-e-research-2026-10-25/artifacts/legado_plus_3.26.03071721_releaseS.apk`
- APK SHA-256：`32a0bb69245a38d0d427a3ea929423d42bee0f5ebdb4942745813b00106527a6`
- REA 6.8.0，JADX headless 0.7.1；引擎摘要：`6e5eacf500b64292bfb73c49797c1958f6ee44646e43e868039ae7feb573ff75`
- APK 包名 `io.legado.app.releaseS`，versionCode 17185。未安装、未运行、未验证签名或测量实体设备帧率。

关键观察：

1. 源码 `PageAnim.coverPageAnim = 0`。实际 APK 的 `ReadView.k(boolean)` 在模式 0 创建 `nn.b`。结合相同模式分支、方法行为与对应提交的源码，可将 `nn.b` 推导为覆盖翻页实现；这是行为对应，不能当成 R8 官方映射文件。
2. `nn.b.r()` 在开始时记录当前页和相邻页；`nn.b.k(Canvas)` 使用裁剪和位移绘制；`nn.b.i()` 在取消标记未设置时才提交翻页。
3. `ReadView.dispatchDraw` 委托当前翻页实现绘制；构造函数设置默认动画时长 300 ms，并持有前/中/后三个页面。
4. `PhotoView.dispatchTouchEvent` 将事件交给 GestureDetector 和 ScaleGestureDetector，识别多指，并在手势结束时约束缩放、校正矩阵。此反编译方法支持“多指缩放和结束归位”的结论；双击细节另参考源代码和 Flutter PhotoView，不扩大这一条二进制证据的含义。

本轮 REA Evidence：

| 内容 | Evidence ID |
| --- | --- |
| APK 元数据 | `ev_e15dfb4ae690a3585d94e982150ecd3b8c7d3871894ceea3261c959b15c49b65` |
| ReadView 方法清单 | `ev_bc70945e174037a3e04e7af21e5db8ab897bd1cb4db8eece9825149960afd02a` |
| 模式选择 | `ev_e93616d79d1760de528196d840c0213ab51e064d647b2f4a5795fc6c7b67e77d` |
| 覆盖绘制 | `ev_d041a1daabfa2e4fb96e358cd90da2e241ef29962cc59c65397c423dda31da33` |
| 页面准备 | `ev_76f58f0b461403083c4d59c010903c95980ddaf8b6d3c6e719cbc6b563b7edbb` |
| 动画结束提交 | `ev_d856d11bce6364eb9cf36b18a90d9b4c483672e1927fedc406ded05c67fd8bfd` |
| PhotoView 触摸处理 | `ev_84b5491cc3465653ebdd1f9c97b05fb003d27a501b6f49b3800ebd22ae6b5c2b` |

精确类名 `CoverPageDelegate`、`PhotoDialog` 的初次查询未找到，因为发布包经过混淆。没有把“名字搜不到”当成“没有功能”；后续从 ReadView 的实际类型分支定位覆盖实现。PhotoDialog 的保存功能不在已核验的这个弹窗类中，不声称通过 REA 验证了它的保存链路。

可复核源码：

- [PageAnim](https://github.com/Luoyacheng/legado-E/blob/624b9b9d21f9f7941c428ba4d6ae209dfb8aa2ed/app/src/main/java/io/legado/app/constant/PageAnim.kt)
- [ReadView](https://github.com/Luoyacheng/legado-E/blob/624b9b9d21f9f7941c428ba4d6ae209dfb8aa2ed/app/src/main/java/io/legado/app/ui/book/read/page/ReadView.kt)
- [CoverPageDelegate](https://github.com/Luoyacheng/legado-E/blob/624b9b9d21f9f7941c428ba4d6ae209dfb8aa2ed/app/src/main/java/io/legado/app/ui/book/read/page/delegate/CoverPageDelegate.kt)
- [HorizontalPageDelegate](https://github.com/Luoyacheng/legado-E/blob/624b9b9d21f9f7941c428ba4d6ae209dfb8aa2ed/app/src/main/java/io/legado/app/ui/book/read/page/delegate/HorizontalPageDelegate.kt)
- [CanvasRecorderApi29Impl](https://github.com/Luoyacheng/legado-E/blob/624b9b9d21f9f7941c428ba4d6ae209dfb8aa2ed/app/src/main/java/io/legado/app/utils/canvasrecorder/CanvasRecorderApi29Impl.kt)
- [PhotoDialog](https://github.com/Luoyacheng/legado-E/blob/624b9b9d21f9f7941c428ba4d6ae209dfb8aa2ed/app/src/main/java/io/legado/app/ui/widget/dialog/PhotoDialog.kt)

源码还显示：渲染记录器可复用 Picture / RenderNode，在硬件画布上重放。这是避免每帧重新排版的参考，不表示 Flutter 必须另写 Kotlin RenderNode 阅读引擎。

### 2.2 Anx Reader：Flutter 结构与图片交互参考

- 仓库：[Anxcye/anx-reader](https://github.com/Anxcye/anx-reader)
- 本地固定提交：`356b7183e8463e7c60d84a72502d0055e55a19fd`（v1.14.0）
- 本轮为源码分析，没有反编译它的 Flutter AOT，也没有运行该应用。

[ImageViewer](https://github.com/Anxcye/anx-reader/blob/356b7183e8463e7c60d84a72502d0055e55a19fd/lib/page/book_player/image_viewer.dart) 使用 PhotoView、独立控制器、全屏预览、关闭/保存/分享按钮。[EPUB 入口](https://github.com/Anxcye/anx-reader/blob/356b7183e8463e7c60d84a72502d0055e55a19fd/lib/page/book_player/epub_player.dart) 的 onImageClick 把图片交给独立路由，适合 LiteTale 的 Flutter 架构。

可借鉴交互结构，但不原样复制两个实现细节：

- 当前参考版本在 build 中解码 base64，LiteTale 应在资源服务中读取一次并复用，避免缩放时反复分配大块内存。
- [SaveImg](https://github.com/Anxcye/anx-reader/blob/356b7183e8463e7c60d84a72502d0055e55a19fd/lib/utils/save_img.dart) 部分保存失败/异常路径仍返回 true；LiteTale 必须按实际写入结果反馈。

Anx 使用 `photo_view ^0.15.0`。调研时 [PhotoView 官方包](https://pub.dev/packages/photo_view) 发布版本为 0.15.0，提供缩放、拖动、控制器及图库；本轮未验证它与 LiteTale 的实际 SDK/路由组合，实施时需先做小范围集成测试。备选是 Flutter 自带 [InteractiveViewer](https://api.flutter.dev/flutter/widgets/InteractiveViewer-class.html)，但需自行补齐双击、缩放复位等交互，因此优先验证 PhotoView。

### 2.3 Readest：图片保存、清晰度与失败回退参考

- 仓库：[readest/readest](https://github.com/readest/readest)
- 本地固定提交：`3cc39ad7a558e6612e1a8135058fbd6f3c90b3e3`（v0.12.16）
- 本轮为源码分析，未运行它的应用或测试。

[ImageViewer](https://github.com/readest/readest/blob/3cc39ad7a558e6612e1a8135058fbd6f3c90b3e3/apps/readest-app/src/app/reader/components/ImageViewer.tsx) 区分适屏比例与原始像素比例，并限制放大后的渲染尺寸；Android 先尝试相册，失败时回退文件导出。分享、导出结果也区分处理。

[保存测试](https://github.com/readest/readest/blob/3cc39ad7a558e6612e1a8135058fbd6f3c90b3e3/apps/readest-app/src/__tests__/components/ImageViewerSave.test.tsx) 具体覆盖 Android 保存和失败回退，值得借鉴用例。WebKit 的布局尺寸重提交是它的 Web 实现细节，不能直接套进 Flutter 原生图片组件。

许可证文件核对：本工程与 Legado-E 为 GPL-3.0；Anx Reader 和 PhotoView 为 MIT；Readest 为 AGPL-3.0。建议翻页移植 Legado 思路并保留适用声明，图片优先复用 MIT 组件；Readest 在此仅作行为和测试用例参考，不整段搬入其实现。

## 3. LiteTale 当前代码的缺口

| 位置 | 已确认现状 | 所需接入 |
| --- | --- | --- |
| `lib/services/reader_page_controller.dart` | turn 使用 jumpToPage，因此点击立即换页 | 覆盖翻页控制器，完成后一次提交页索引 |
| `lib/pages/novel/reader_page.dart` | 普通模式为 PageView；点击、音量键、边界切章各有既有入口 | 共享翻页调度；保留章节边界策略、双页逻辑和旧状态失效保护 |
| `lib/widgets/reader_paper_view.dart` | ReaderPaperLeaf 能显示普通图片、特殊页面和 CSS 整页位图；没有图片预览入口 | 普通图片的真实显示范围命中；CSS 走热点元数据 |
| `lib/pages/novel/html_reader_page.dart` | 滚动图片只有 Image；固定 4:3 容器可能产生较大留白 | 使用同一预览入口；命中实际图片范围，避免留白误触 |
| `lib/widgets/cached_image.dart` | 图片来源区分文库8下载缓存、本地资产和其他源请求头 | 抽出共用原图读取服务，让正文、预览、保存共用同一来源策略 |
| `lib/models/reader_page.dart` | ReaderCssPage 只有页号、DOM文本范围、截图读取函数 | 另加插图 ID、资源键、显示区域、渲染版本等元数据 |
| `lib/assets/epub_page_engine.js` | prepare/select 返回分页文本范围；没有可点击插图区域清单 | 渲染完成时采集可见插图区域；不逐帧遍历整本 DOM |
| `lib/widgets/reader_volume_turn_scope.dart` | 已检查 ModalRoute.isCurrent 和前台状态 | 图片预览使用独立路由，使底层不响应音量翻页 |
| `lib/services/hardware_turn_buffer.dart` | 已有最多4项、1.5秒有效期的短输入缓冲 | 复用并检查跨路由清空；不再另叠一个无限队列 |
| `ios/Runner/Info.plist` | 现有相册用途说明用于选择阅读背景，没有新增图片所需的 add-only 文案 | 增加保存用途文案及对应 PhotoKit 路径，不能混用“选择背景”说明 |

目前仅在静态代码中确认缺口，不能据此宣称六个远端源的插图均已在线测试成功。

## 4. 覆盖翻页的移植设计

### 4.1 使用 Legado 的标准覆盖模型

把当前已排版页面和相邻页面作为可复用的纸张，叠在同一个视口中：

- 下一页：下一页在底层，当前纸张向左离开，露出下一页。
- 上一页：上一张纸从左侧移动回来，覆盖当前页面。
- 两张页面不一起移动，不采用交叉淡入淡出。
- 这是 Legado 的标准覆盖逻辑。它与用户最初“新页从右侧进入”的字面描述不同；用户已明确允许以成熟项目实现为准，故优先采用标准行为。

Flutter 接入应复用 ReaderPaperView、ReaderViewportLayout 和 ReaderRasterReadiness，用 Stack + 位移/裁剪重放已就绪页面。单纯把 jumpToPage 改成 animateToPage 只会得到推页，不是这一模式。

每张纸必须包含**不透明纸色、纸张纹理、标题和正文**；不能只平移文字层。阴影只在纸边，避免出现过去的透字、两页文字叠加、背景闪烁。

### 4.2 翻页生命周期

建议状态为 idle → preparing → dragging/settling → idle：

1. 捕获当前 book/source/revision、章节、版式及目标逻辑页。
2. 当前与相邻纸张准备好后开始动画。图片错误也应成为可绘制的错误占位状态，不能卡住整个翻页。
3. 动画期间只更新位移，不进行测量、分段、章节解析或 WebView 截图。
4. 完成时提交一次阅读位置，再交换页面角色；取消回到原页，不提前写入历史。
5. 字体、横竖屏、字号、双页布局变化或离开路由时，使旧动画回调失效，避免旧任务把新书位置覆盖。
6. 跨章继续使用现有边界逻辑与已完成的本地整书衔接，不插入“点击下一章”中间页。

初始动画时长可在约 220–300 ms 范围调试，以 Legado 的 300 ms 为参考；拖动跟手、释放按剩余距离收尾。系统关闭动画时尊重辅助功能设置。最终时长需实体设备验收，不能只凭模拟器判断。

连续点击和音量键进入同一调度。保留现有有界音量缓冲，防止加上动画后旧 busy 判断直接吞键；预览图片、进入菜单、切后台后不能积压输入，退出时突然连翻。

横屏以一个 ReaderViewportLayout 的逻辑视图为单位，包含左右两页；不在动画中重新分页或把文字拉过书脊。

## 5. 全部书源统一图片能力

### 5.1 原图服务与预览器

建议引入 ReaderImageRef → ReaderImageRepository → ReaderImageViewer / ReaderImageExporter：

- ReaderImageRef 明确图片所属书源、书籍、章节、URL或本地资源键、原始类型及 revision；不能只从当前首页 activeSource 判断来源。
- ReaderImageRepository 读取原始字节/受控缓存文件；正文显示、预览、保存共用。已有原图优先复用，重复请求合并，调用者独立取消。
- ReaderImageViewer 使用 PhotoView，全屏显示，初始适屏、双指缩放、双击放大/复位、拖动查看，关闭回到原阅读位置。
- ReaderImageExporter 取同一份原图。缩略图、页面截图、缩放后的截图不能当成原图保存。

书源适配要求：

| 来源 | 必须保留的资源策略 |
| --- | --- |
| 文库8 | 沿用原有 downloadImage 缓存；插图 CDN 域名可能与站点不同，不能按图片 host 猜书源 |
| 轻书架 | 正确 Referer / 合法会话上下文，不能因预览失败清除账号，也不混淆阅读等级限制 |
| 轻小说百科 | LNovelSource 自有请求头策略 |
| 哔哩轻小说 | 关联该书所属的哔哩图片策略及有效资源地址；失效/受限时明确失败，不把验证页当图片 |
| 幻梦轻小说 | 沿用规则图片头、相对地址解析与来源隔离 |
| SF公开目录与导入规则源 | 使用规则定义的图片头和合法公开资源；公开目录本身不等于所有章节/图片都可读 |
| Android 本地 EPUB | 从校验后的离线资产/出版物资源映射读取，不发外网请求 |

网络仍需有界读取、超时和 MIME/图片解码检查；大图的压缩字节和解码像素分别计量。显示先按视口解码，确有需要再获取更清晰层级，避免把多张巨幅图全部常驻内存。缓存键包含来源和 revision，不把认证相关请求头写进日志。

### 5.2 点击和手势规则

1. 点击实际插图范围优先打开预览；图片旁边/上下的空白仍按原阅读区规则操作。
2. 图片下载按钮、长按菜单等操作不能穿透触发底层翻页。
3. 正文滚动/横向拖动不能在松手时误识别成点击图片。
4. 在预览内，双指缩放与单指拖图优先；先不增加自动切换章节图片的横向图库，避免与拖图冲突。
5. 使用独立预览路由，让既有 ModalRoute / 前台判断阻止底层音量翻页。退出恢复原页和原滚动位置，缩放不记成阅读进度。
6. 关闭、保存按钮使用 iOS / Android 各自现有配色、控件风格；加载显示随主题的普通转圈。

### 5.3 Android EPUB CSS 页的特别处理

当前 CSS 页是整页位图，该路径的 ReaderPage.isImage 固定为 false，不能据此判断页面是否含原始插图。不能把整页图片一律当插图，也不能用整页截图替代 EPUB 中的图。

建议在既有分页渲染器中添加：

- 每张可见图片/内嵌图像的稳定 ID、受控资源键、可见区域和原始尺寸；优先处理 img、SVG中的image及固定页面中的图片，复杂 CSS 装饰另行验收。
- 以当前页实际绘制坐标采集并裁剪区域；考虑 iframe、列偏移、缩放、固定页面居中、图片跨页和横屏双页偏移。
- 隐藏或不可见元素不生成热点；不能拿整个 SVG 标题版面或背景装饰默认充当可保存插图。
- 与当前页、字体、尺寸、书籍 revision 对齐。元数据与位图同版本发布；旋转后旧热点立即失效。
- 图片资源键走 publication.resources / 本地受控读取。CSS 虚拟地址 litetale-epub.invalid 不能交给普通外网 ImageProvider。
- 同一渲染实例内读取热点，与既有串行 CSS 通道协调；不要为点图新建整本 WebView或重新导入 EPUB。

普通位图保存保持原格式。SVG/复杂组合若相册不接受，提供“导出原文件”，必要时另标注“导出 PNG”；不能悄悄转换后声称保存了原图。GIF 应保存动画原字节，不能只存当前帧。

### 5.4 保存到系统相册 / 文件

- **Android 10+：**通过 MediaStore.Images 写入应用新创建的图片，使用正确 MIME、文件名、RELATIVE_PATH 与待提交状态；不为保存自己创建的图片申请读取所有照片或管理所有文件权限。失败/取消走明确结果，必要时回退系统文件保存。
- **Android 9及以下：**可优先系统文件保存，避免强制扩大存储权限；若选择旧系统相册直写，必须单独处理该版本所需权限，不能套用 Android 10 的规则。
- **iOS：**需要保存到照片时才申请 PhotoKit add-only 权限，并配置 NSPhotoLibraryAddUsageDescription；拒绝时仍可预览并使用系统导出/分享。分享表单关闭不等于“已存入相册”。iPad 的分享锚点需有效。
- 文件名可含书名、章节、图片序号并净化非法字符；使用不覆盖现有文件的策略。保存中禁止重复提交，成功后再提示完成；不自动批量保存。

以上依据官方资料：[Android MediaStore](https://developer.android.com/training/data-storage/shared/media)、[Apple PhotoKit 权限说明](https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app)。Apple 页面 Markdown 原文已补充读取，以核对 add-only 要求。

## 6. 实施次序与验收

### P0：标准分页覆盖与全部在线书源插图

- 移植覆盖翻页状态和纸张绘制模型，接入现有控制器。
- 抽出原图服务，接入所有当前内置源及规则源策略。
- 普通分页插图、在线滚动插图统一进入预览器。
- 实现保存结果、权限、格式和文件回退处理。

### P1：Android EPUB CSS 插图热点

- 扩展 JS / Kotlin / Dart 元数据合同。
- 普通、固定版式、SVG引用图片、跨页图片和横屏双页命中。
- 回归原书 CSS、缓存复用、连续跨章节翻页和导入后的分类管理。
- iOS 本地仍由 Apple Books 控制；不把这部分算作 LiteTale 已实现的预览功能。

### 必须验收的场景

| 类别 | 检查点 |
| --- | --- |
| 翻页 | 下一页/上一页、点击/拖动/音量键、取消拖动、连续输入、章节首尾、重新排版、横屏双页、离开路由、关闭动画 |
| 页面正确性 | 无透字、无空白闪帧、无文字二次排版跳动；取消不改历史，完成只提交一次 |
| 在线源 | 六个内置源逐一选择可读且含图的章节；首次加载、已缓存、失效/403/500、登录状态变化分别测；不能只测文库8 |
| 图片命中 | 图像本体能点，contain留白不误点，滚动不误触，预览里按钮不穿透 |
| 缩放 | 双指、双击、拖动到边缘、旋转、关闭后阅读位置保持；无新增底层音量翻页 |
| 保存 | 原图摘要一致（可原样导出的格式）、扩展名/MIME正确、长图/大图、GIF、SVG导出、无权限、磁盘不足、取消与重复点击 |
| 本地 EPUB | 离线可用；插图与文字混排、跨页、固定布局、双页中缝；不损害之前的 CSS、整书衔接、批量导入和分类 |
| 性能 | 分别测准备等待/动画/UI与光栅耗时、原图读取/解码/写入耗时、峰值内存；禁止按每帧重新截图 |

性能应在实体 Android 与 iPhone/iPad 的 profile/release 构建中测量；目标是动画期间不出现重复排版/解析，持续帧耗时匹配设备刷新率。研究阶段没有测得“稳定60/120帧”或“所有书源秒开”，不作这些承诺。

## 7. 本轮产物与边界

REA 文件：

- `build/qa/reader-cover-images-research-2026-11-02/rea-evidence-bundle.json`：22条本轮 REA 证据。
- `build/qa/reader-cover-images-research-2026-11-02/selected-rea-evidence.json`：与翻页、预览直接相关的证据。
- `build/qa/reader-cover-images-research-2026-11-02/manifest.json`：固定引用、文件摘要和调研范围。
- `build/qa/reader-cover-images-research-2026-11-02/validation.json`：研究产物检查、HEAD/暂存区及16个相关生产文件保持不变的核对。

本轮没有修改应用代码、依赖、原书或账号数据，没有启动新代理，没有重复执行前一轮已通过的952项 Flutter测试，也没有进行远端书源在线验收或设备交互测试。REA 已导出证据并关闭分析资源。

