# 详情页与单本封面加载：Yomiru / Novella 调研

日期：2026-11-02。工程 `D:/Projects/LiteTale`。本轮只调研与制定方案，未修改已交付 1.2.0 的应用代码、版本或安装包。

## 按用户最新澄清收窄范围

**首页整页加载时转圈保留。** 本轮要学习的是书目已经出现后，每一本封面怎样占位、读取、过渡与复用；不把首页整页状态改成骨架屏，也不改全局加载指示器。

另一个任务仍是参考两款应用的书籍详情页布局。两张用户截图作为视觉参考；可观察行为、公开源码事实和 LiteTale 拟采用方案分开记录。

## 研究对象与证据

| 项目 | 固定版本与源码 | 正式安装包 |
| --- | --- | --- |
| [Yomiru](https://github.com/hesitation-snow/Yomiru) | v1.6.0，`1c0e43f3d1c70b9a5126c4dbda529be3b92a18be` | 官方 universal APK，74,848,749 字节；SHA-256 `a5da1791c1bca3281e831eedf0ff524786475208d168479e93ea11148de2ef14` |
| [Novella](https://github.com/celia-sh/Novella) | v2.7.0，`bedd62c5a20aa80e9bf922b33ea12887d991aa8a` | 官方 IPA，29,786,138 字节；SHA-256 `9948a1474ae7357b1541a10e53bd7071f0caf53542b6939bd1717c4702142ea7` |

两个摘要均与 GitHub Release 的 asset digest 相符。包、固定源码摘录、截图、录像和索引保存在 `build/research/cover-details-2026-11-02/`。GitHub 连接用于读源码和发行信息；其不支持二进制下载，故官方包通过 GitHub CLI 下载，没有执行下载来的安装包代码之外的仓库脚本。

REA 证据：

- Yomiru Flutter 构建识别：`ev_c257c8daa0bab9658f14f6f10a29721e43c6a1fa9178545898dc1b8586a880c4`。arm64 应用库摘要 `e65d3fceaed14fd3b3c157d2ba6bccafeed1a1ed6d5e2cf4833d99f7aaae2e84`。
- Yomiru APK 清单：`ev_94b83a729d44350d477ca793bfca0c672149e46a2bc6c1a41a77504c883a272d`。包名 `moe.yutro.yomiru`，1.6.0/build14。
- Yomiru 首页、同一本书详情、更新列表的 REA 屏幕证据分别为 `ev_62230fd82cdfafec6a7eda8b45b82f46a99ddca716afc8959bcb3e873bf5033c`、`ev_1fa201c2746eca10094f2002f39afcb5701413b1af9173565b001111907623f8`、`ev_002853bf9c04f1e9bc50b7b7098e8bed9fd9af6de09321a73e3a4c8d560ccd53`。
- Novella IPA 库存：`ev_c2058083b45094e2a6810fa9a9bab62ccfa0a0a9e6726d05e35a5a59d0ce49da`；底层库存 `ev_8a4c8aa03537b2baa8ef531128d01b4dee32832451c4894c86df60a51faf61a6`。
- Novella 选定主程序、Info.plist 与 JS bundle：`ev_4ed100573ffd67f8b3ec5a52eb5155bb4e856bff6473d4e50b5967b071ea17da`。包内版本 2.7.0/build476，标识 `sh.celia.novella`；Hermes bundle 17,429,871 字节，SHA-256 `ce29100045edd621a2cba1e1fcd530d74facbe43b3ec5851d14ef3724b2c48ac`。

证据包 `rea-evidence-archive.json` 保存切换/关闭 REA 会话前的记录；后续截图与清理另保存在 `rea-evidence-final.json` 和运行时证据包。不能把导出的单个新会话文件当成全部历史。

## 单本封面：Novella 已能确认的实现

固定源码入口：[BookCoverImage](https://github.com/celia-sh/Novella/blob/bedd62c5a20aa80e9bf922b33ea12887d991aa8a/apps/mobile/src/components/book-cover-image.tsx)、[缓存键](https://github.com/celia-sh/Novella/blob/bedd62c5a20aa80e9bf922b33ea12887d991aa8a/apps/mobile/src/services/cover-image-keys.ts)、[显示尺寸](https://github.com/celia-sh/Novella/blob/bedd62c5a20aa80e9bf922b33ea12887d991aa8a/apps/mobile/src/services/image-sizing.ts)、[封面激活范围](https://github.com/celia-sh/Novella/blob/bedd62c5a20aa80e9bf922b33ea12887d991aa8a/apps/mobile/src/hooks/use-cover-activation.ts)。

| 环节 | 已确认行为 | 对 LiteTale 的意义 |
| --- | --- | --- |
| 等待单张图片 | 有合法 BlurHash 时先绘制 32×48 模糊预览；没有则显示主题底色与书本图标。加载指示器只是该书封面上的小覆盖层 | 占位属于每本书的封面，不牵连整页转圈 |
| 第一次显示 | `expo-image` 负责 200ms `cross-dissolve`，在 `onDisplay` 后等待过渡完成才撤下底层预览，避免中途露空底 | 应按真正的首帧就绪切换，保持图片区域尺寸不变 |
| 再次显示 | 已显示封面记录最多 256 项；默认 `animateCachedImage=false`，命中过往显示记录时不重复过渡。原图使用 `memory-disk` | 切标签、详情返回、列表复用时直接显示已看过的封面 |
| 列表复用 | 解码缓存键保留签名和尺寸参数，只移除确定不影响字节的 `placeholder`；`recyclingKey` 用完整请求地址 | 防止复用单元格短暂显示上一本书，不能随意删所有 query |
| 读取/解码尺寸 | `allowDownscaling`、`enforceEarlyResizing`；CDN 高度按实际显示高度×像素比，每 256px 分桶，上限 4096px | 列表不用按原始超大图解码；跨源缩图 URL 必须遵守各站真实能力 |
| 请求范围 | 当前可见行加附近一行才激活真实网络图片，离屏位置可先保留已有占位 | 避免首页刚就绪就同时下载整个列表；不是按顺序故意延迟每一本 |
| 失败 | 首次失败有一次 200ms 后重试，之后保留占位与可点击重试图标；点击重试不触发打开书籍 | 各封面失败独立处理；LiteTale 仍须遵守自身 429/Retry-After 与取消规则 |

源码有一个 `MINIMUM_PLACEHOLDER_DURATION_MS=120` 声明，但该文件没有使用它，不能据此报告“每本封面强制等120ms”。另一个 `min-skeleton-display.ts` 的 500ms 用于页面数据骨架，不属于本轮封面方案，不引入 LiteTale。

Novella 仍可在单本封面上转圈，它的改善来自占位底层、首帧过渡、缓存复用与尺寸控制的组合。仅加淡入不能改善真实网络耗时。

## 单本封面：Yomiru 能确认与未知的部分

其 [公开源码说明](https://github.com/hesitation-snow/Yomiru/blob/1c0e43f3d1c70b9a5126c4dbda529be3b92a18be/source/README.md) 明确只发布筛选后的阅读组件，不包含完整业务页面与图片请求实现。因此公开 `source/pubspec.yaml` 的 1.5.0+12 也不能代表正式 APK 的构建依赖。

已用 REA 识别正式 APK，并在 Android API35 模拟器安装、启动，未登录账号，打开了用户第一张图对应的《一周一次买下同班同学的那些事》。确认首页返回时原封面仍在，详情页封面可复用已有内容。实际安装包的 arm64 字符串含 `CoverImage`、`CachedNetworkImage`、`CachedNetworkImageProvider`、`OctoImage`、`ImageCacheManager`、`ResizeImage`。

这些字符串可支持“正式包包含这些图片组件”的判断，**不能证明其具体调用关系、缓存容量、淡入曲线或时长**。REA 的 Dart AOT 读取器明确不支持该包的 unified snapshot；没有反复重试，也没有把未恢复的 Dart 代码当成已反编译结果。

另补录 `yomiru-single-covers-research.mp4`，在已有书目里向下滚动到未完成加载的封面，确认了本轮真正关注的单图行为：**紫色系主题渐变底与书本图标先占位，原图随后在同一框内逐渐显现，文字和卡片框位保持稳定**。接触表 `yomiru-single-covers-contact.png` 中约5秒和6.5秒可见部分封面过渡中的状态，后续帧为完整封面。该录像只能支持这种可见行为，不能从约10fps的编码视频精确断言原应用的曲线与持续毫秒数。最终列表屏幕证据为 `ev_14e5ec148f595375e494fb475d9f46c39ff85d4431920a041a99a2c572051f9a`。

前一段录像记录“详情返回原列表”和“首次切换新列表”；前者保留封面，后者在该次网络中仍等待整页数据。这只用于划清数据等待和单图加载，**不是提出替换用户认可的首页转圈**。录像编码帧率不是应用真实绘制帧率，不能当作帧率/网络性能基准。

## 详情页取舍

Yomiru 的同书运行截图与用户参考都确认了明确的信息层级：封面、书名/作者、连载状态/卷章数/字数；分类；收藏/书评；简介；可折叠分卷目录与章数；阅读入口。信息完整时很适合长篇多卷轻小说。

Novella 的 [详情页](https://github.com/celia-sh/Novella/blob/bedd62c5a20aa80e9bf922b33ea12887d991aa8a/apps/mobile/src/screens/book-detail-screen.tsx) 更强调封面、封面配色背景、开始/继续阅读主按钮和独立收藏按钮。进入详情时可先带入列表的封面、书名和占位信息，再补齐详情。简介为空时不绘制简介区。竖屏渐变与横屏镜像封面模糊背景是两种路径，不应统称成“整页大图高斯模糊”。

建议后续设计：

1. 移动端顶部使用固定比例的封面与清楚的书名/作者信息，标签与卷章数次之；平板加大封面并重新分配头部空间，下方操作与目录继续全宽可滚动。
2. 开始/继续阅读是明确的主操作，收藏和书评保留独立入口；不让按钮挡住目录末行。
3. 分卷目录采用 Yomiru 的独立行卡片、章数和明确展开状态，保留全部展开/收起及阅读进度定位。
4. 简介过长可展开或进入完整简介；为空不预留大块空白。标题与正文中的“简介”重复需针对数据处理，不笼统删除正文词句。
5. 字数、热度、上传者、关注等只在当前书源确实提供且支持操作时显示；不把六个来源缺失字段补成虚假计数或无效按钮。
6. iOS 保持系统色、系统控件与现有液态玻璃，Android 保持 Material You。封面色只用于详情局部氛围及适当强调。Novella 当前配色代码实际使用 Material 色彩算法，不把它整套照搬为 iOS 系统语义色。

## LiteTale 的当前入口与差距

- `lib/widgets/cached_image.dart`：`frameBuilder` 在 `frame==null` 时画底色与图片图标，首帧一到直接换为图片，没有单张封面的渐进过渡或持久缩略占位；`CachedImage` 还服务阅读插图，不能全局套封面动画。
- `lib/widgets/apple_book_cover.dart`、`novel_cover_card.dart`、`novel_card.dart`：封面入口已基本汇合，保留既有两行标题槽和卡片尺寸，封面阶段改造应在此接入专用组件。
- `lib/services/reader_images.dart`：源/会话代数隔离、合并请求与有界原字节缓存已具备。文库8走原 Rust 下载缓存，其他来源不能误写成已有完整持久磁盘封面缓存。
- `lib/pages/novel/novel_info_page.dart`：详情先等完整数据，头部封面为120×160并裁切；列表多数只传书号，无法立即绘制已有书名与封面。后续可增加兼容旧路由的轻量展示提示，不把提示当完整目录或更换书籍身份。
- `lib/widgets/discovery_tab.dart` 的标签保活、首页整页 `SourceLoadingIndicator` 与底部导航本轮不改。

## 建议实施顺序：先单图，再详情

### 第一步：独立封面显示组件

建立仅供书籍封面使用的 `BookCoverImage`，保持现有阅读插图路径。

单图顺序：已有解码帧直接显示 → 已有本地缩略占位显示 → 没有缩略时用该图大小的主题占位 → 首次新图真实首帧就绪后约180–200ms短过渡。缓存命中、旋转重建、标签返回不重复转圈/淡入；系统减少动态效果时直接显示。占位和图片始终同框，不出现布局跳动。

BlurHash 的来源先核对书源原始字段；Novella 使用的数据不能假定六个源都提供。无该字段的来源，在正常解码成功后生成有界的小缩略缓存，供下次使用；首次未知图片使用主题占位，不额外请求原图来“提前生成占位”。拟从32×48缩略、最多256条/8MiB起步，再以实测调整。

### 第二步：复用与读取控制

图片身份覆盖书源、URL、会话隔离要求及解码尺寸，签名参数不随意剥离。可见图片优先，附近最多一行适度预读；预读不能抢正文、登录和目录队列。只对确有缩图协议的来源请求 CDN 变体，其余沿用原请求头/原地址，在设备端按显示像素解码。沿用预算、限流及失败语义，不因占位动画增加重试风暴。

### 第三步：详情展示与同图复用

从列表带入可选书名、封面、已知预览，使详情头部先有内容；真实详情仍走当前有界缓存与来源校验。调整封面比例和头部排版，再接主操作、简介与卷卡片。配色从已有预览/小采样取得，未就绪使用当前主题；不为取色另下大图，不把整个页面重新推倒淡入。

## 后续验收要求

- 六内置来源与规则源：首页整页等待继续正常转圈；已显示的书目布局不变；只改变其中单张封面的呈现。
- 冷图、内存命中、磁盘/缩略命中、坏图与手动重试分别验；同一封面多处显示只做一次实际读取，返回列表保持旧帧。
- 快速滚动/换标签/换源/账号变化不串图；失败重试不打开详情；不存在的图片不无限转圈。
- 动画期间卡片位置、标题基线和触摸范围不变；小屏、大字、浅深色、iPad与Android平板分别看。
- 记录图片任务的排队、读取、解码和首帧显示耗时，区分网络慢与显示慢。不靠强制等待让缓存图看起来“有动画”，不承诺动画会让原网站变快。

## 调研完成度

Novella：单图占位/过渡/缓存/请求尺寸、详情结构与配色路径已由固定源码确认，并以正式IPA清单与包内字面量交叉核对；未在iPhone运行，也未将Hermes字符串当作完整反编译。

Yomiru：正式APK身份、Flutter组件痕迹、公开首页与同书详情运行、单本封面的渐变占位和渐进显现已确认；单图相关实现不在公开源码中，AOT格式不被当前REA读取器支持，具体曲线与缓存配置仍未知。方案按可观察设计学习，未声称直接完整移植其未公开实现。

本轮没有改首页转圈、应用代码、1.2.0安装包或版本号；研究输出不等于功能已经落地。
