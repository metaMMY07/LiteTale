# LiteTale 工作约定

- 2026-11-03 v1.2.1：先读 `docs/READER_CONTROLS_1.2.1.md`。用户确认点击/音量没问题，360ms和AppDelegate音量实现不改。普通滑动越过完整页后携带剩余距离，不等收尾锁页；父索引回显与真正外部seek须区分并清理确认记录。新统一ReaderSettingsPanel/浮动ReaderToolbar，分页底部只松手跳本章页，不把EPUB有界窗口算整书总数。iOS滑杆必须走UIKit UISlider原生液态玻璃而非Cupertino圆头，自定义thumb会覆盖原生效果；范围/章节旧事件过滤，横向/点击recognizer不抢纵向列表。iOS系统黑白灰+systemBlue/可选原生色，保留custom RGB重启；不能用Material seed预览冒充iOS配色，Windows fallback截图不算UIKit实测。Android使用原Material You色盘/分组，应用毛玻璃底栏、书源/封面/详情不动。55相关检查/16目标分析通过，实体手感和玻璃外观交用户验证，内部Android88。

- 2026-11-03 手势/音量追加：先读 `docs/READER_GESTURE_VOLUME_FIX_1.2.0.md`。用户保留点击节奏；修复后台移除拖动后resumed未重建的首滑失效，拖动松手用SDK分页弹簧承接速度，点击/音量360ms不动。iOS改typed KVO/slider.value实际回读及有限失败，基线回调不按250ms超时变成反向键；原音量/新输出路由/旧清理隔离；音频通知在主队列按独立监听代数过滤旧回调。ReaderVolumeState纯Swift策略随设备构建运行6组检查，不能将其或模拟器说成真机音量验收。仍v1.2.0且交付文件不加build，Android内部87；来源、配色、封面/详情/页脚不重做。

- 2026-11-03 视频翻页追加：先读 `docs/READER_SLIDE_FOOTER_1.2.0.md`。用户明确覆盖旧“无时间/页码”要求；用户随后澄清要去掉的是翻页中两张页面交界的竖线，并非横屏中缝；普通动画已无阴影分隔且两页共用物理像素对齐位移。普通分页现在为两页同步水平平移，360ms缓起缓停，拖动可接管点击收尾，仅完成才提交。时间/本章页数放独立ReaderFooter，分钟更新不触动正文；共用布局预留页脚，固定图文与热点一起等比适配。本地页码必须按所属完整章节，不按有界预读窗口算整书总数。Android独立仿真选项/iOS Apple Books仍保留原逻辑，封面/详情/配色不动。本轮交付仍v1.2.0且文件名/关于页不显示build；内部平台代码只用于覆盖安装。

- 2026-11-02 最新追加：用户授权iOS详情分类标签改胶囊，并指出Android旧配色没完全恢复。先读 `docs/IOS_CAPSULE_ANDROID_PALETTE_1.2.0_FIX3.md`。只改详情标签，其他已验收布局不重做。胶囊须Flutter StadiumBorder与原生surface/玻璃同半径，不能只套外裁剪。Android底栏选中色恢复1.0.0 primary/primaryContainer及旧毛玻璃底色，materialSurface不再额外灰色混合，保留动态色/自选色/新卡片几何。Android导入ios-*色名映射旧预设，iOS色盘不动。13针对性检查通过，版本1.2.0+85；84APK和iOS26只有封面渐变，不包含此追加项。

- 2026-11-02 封面渐变修复二：先读 `docs/COVER_FADE_1.2.0_FIX2.md`。用户确认详情完成，禁止本轮改详情布局/主题。同步解码和预加载不等于已显示；封面真实paint后才登记/开始过渡，不能恢复build83的`synchronous`直接跳过。iOS所有来源200ms原生ease-in-out交叉渐变、无BlurHash源用同帧32×48层模糊底；Android主题色底与500ms单图渐变。已实际显示/减少动态效果直显。下载三页补接统一组件。Yomiru私有封面未提取，不得谎称完整反编译移植；Novella与Expo时序已按固定源码适配。10针对性检查通过，详情/主题散列未变，仍按用户要求只做必要构建与交付，版本1.2.0+84。

- 2026-11-02 封面/详情实施：先读 `docs/COVER_DETAILS_1.2.0_FIX1.md`。用户已授权 Android 参考 Yomiru、iOS 参考 Novella，详情必须多源通用；Android 恢复 1.0.0 色阶但保留毛玻璃底栏和几何，iOS 原生选色/玻璃保留。首页整页 spinner 不改，首帧动画仅封面，不能给 reader 插图加动画；缓存/已显示/减少动态效果直显。小预览 RAM 256项/8MiB、最多2活动无队列；原图仓库和文库8磁盘缓存沿用，source/revision 隔离。分卷/继续阅读/书架/书评按真实能力显示，保留原登录和站点恢复。用户要求尽快交付 APK+IPA 并自行测试，仅13针对性检查及目标分析通过，不重跑全量或声称实体已验；版本1.2.0+83，构建使用独立临时 index。

- 2026-11-02 详情/封面研究：先读 `docs/research/DETAIL_COVER_RESEARCH_2026-11-02.md`。用户已澄清首页整页转圈保留，只学习每本封面占位、首帧过渡、缓存再次显示；不能借此改首页为骨架屏或全局Loading。REA核验Yomiru1.6.0 APK与Novella2.7.0 IPA；Yomiru模拟器实际同书详情与新封面录像确认主题渐变占位后逐渐显现，但业务源码未公开、unified Dart AOT不被当前读取器支持，曲线/容量未知。Novella固定源码确认32×48 BlurHash、200ms cross-dissolve、memory-disk、256显示记录、尺寸分桶与可见附近行激活；120ms占位常量未使用，500ms页面骨架等待不引入。后续拟用专用封面组件，不能给Reader插图全局加动画；缓存直显、无额外请求制造占位。详情借鉴Yomiru卷卡和Novella封面头部，保留iOS系统色/玻璃与Android Material You。仅调研，未改1.2.0生产代码/包/版本；未运行Novella iOS，不把库存/字符串写成动态实测。

- 2026-11-02 1.2.0 已封装：先读 `docs/READER_IMAGES_1.2.0.md` 和 `docs/releases/1.2.0.md`。普通阅读用 Legado 标准覆盖状态机，完成才提交位置，短拖取消；本地章节追加不能取消正在翻动的页，双页半幅补齐需刷新缓存。六内置源/规则源阅读插图共用原字节缓存与独立 PhotoView，保留 source/revision/请求头；坏解码须可显式重试，旧失败不得失效新会话。Android CSS EPUB 热点映射原资源，流式/固定/SVG 位图都要测，不能导出整页截图；PTQ 原生页点图优先于翻页。相册只添加自有图片，导出取消与失败/成功分开；iOS 本地 EPUB 仍用 Apple Books。包含此前批量导入与分类。最终968通过/14跳过、14目标分析及Kotlin/Xcode设备Release编译通过，真实Chromium三版式通过；无实体装机，独立模拟器相册写入测试未完成不算通过。Android1.2.0+82、iOS1.2.0/build24已放下载目录 `LiteTale-1.2.0-20261102/`。独立构建提交bfe4720、CI41385363695成功，两APK签名/对齐和IPA双重复核通过；生产源码快照877项匹配，本机原HEAD/暂存区不变，封装后仅补发布与交接文档。以下“未打包”是此前实施阶段记录。

- 2026-11-02 本地 EPUB 批量导入与分类：先读 `docs/EPUB_BATCH_LIBRARY_2026-11-02.md`。多选使用 openFiles 并保留 EPUB UTI；队列由 LocalEpubLibrary 持有，单重解析、逐本成功/重复/失败，停止只取消未开始项，分类保存失败不能回滚已入库书籍。iOS 批量后不自动打开 Apple Books，单本保持原行为。分类为独立元数据，多分类不复制文件，不改 EPUB ID/原书/CSS/阅读锚点；两槽校验快照、较新 schema/双损坏禁止覆盖，分类目录首次写入才创建。没有新增批量物理删除或文件夹扫描。新增21测试，全量952通过/14跳过，8目标分析无问题；未验实体，iOS截图是widget fallback。版本仍1.1.1+81，未提交或封装；旧build81/iOS23不含此功能。本机原HEAD/暂存区不变。

- 2026-11-01 评论修复一：先读 `docs/SOURCE_COMMENTS_FIX1_2026-11-01.md` 和 `docs/releases/1.1.1-comments-fix1.md`。哔哩评论必须覆盖实际BiliBrowserSession路径，不能只用直接HTTP测试；新增白名单仅reviews_正整数_正整数.html且无query/fragment，不能放开登录/长评全文/跨站。轻书架GetComments补Size10，SignalR成功调用内的业务500也进入既有最多一次重试；401续期/403/429及取消逻辑保留，不重试写入，不清账号、不将500伪造为空评论。真实公开样本有持续业务500，不能宣称所有书恢复。931回归通过/14可选跳过，6目标分析和两种移动配置真实浏览器通过；未验实体。Android1.1.1+81、iOS1.1.1/build23已封装到下载目录 `LiteTale-1.1.1-comments-fix1-20261101/`；源码ad0dc588、设备CI41283268483成功，APK签名/对齐和IPA双重结构校验通过，640构建源码与原分支/暂存区不变。旧build80/iOS22不含此修复。

- 2026-11-01 原站只读评论：先读 `docs/SOURCE_COMMENTS_2026-11-01.md` 和 `docs/releases/1.1.1-comments.md`。文库8补既有同源reviews提取；轻书架用官方GetComments并按需显示回复；百科保留评论/引用；哔哩只展示原站公开书评并跟随实际有效分页，不能把HTML注释掉的分页或登录后内容当公开内容；SF固定sfacg_public/原站Common.ashx区分简评/长评/回复，当前原站维护公告不是普通评论。幻梦检查两本原站详情无评论，不猜接口。评论只在点击后读；24页/2MiB/2分钟缓存，账号/书籍/页码/类型/回复隔离，最后订阅者取消且25秒总预算，刷新失败保留旧内容但重试第一页。全量920通过/14可选跳过，四个新增真实公开读取另行通过（SF仅维护状态），19目标分析无问题。Android1.1.1+80、iOS1.1.1/build22已封装至下载目录 `LiteTale-1.1.1-comments-20261101/`，同源构建提交22384f5、设备CI41270527402成功；APK签名/对齐及IPA结构已验，640构建源码与原暂存区不变。未连接实体设备，不能误报旧build21包含本轮功能。

- 2026-10-31 最新UI要求：iOS选源保持原生液态玻璃下拉菜单，只在菜单外下方显示当前书源网址和“打开原网站”，不得改为卡片选源弹层。已恢复 `AppDropdownButtonFormField → AppleGlassMenu` 并封装为1.1.1/iOS build21，见 `docs/releases/1.1.1-ios-menu.md`。IPA已放下载目录，文件名带ios-21；build20旧包不包含此恢复。31项相关回归、2目标分析、实际上传快照878测试通过／10可选跳过，设备IPA构建21和本机校验成功，实体测试由用户进行。Android仍用1.1.1+79；本地feature分支、HEAD、暂存区不变。

- 2026-10-31 按用户要求封装1.1.1测试版：Android1.1.1+79、iOS1.1.1/build20，先读 `docs/releases/1.1.1-source-sites.md`。下载目录 `C:/Users/30622/Downloads/LiteTale-1.1.1-20261031/`；独立构建提交0095d2d，本地feature分支、HEAD、暂存区不变。工作区及上传快照878通过／10可选跳过，APK签名和对齐／IPA结构校验通过，设备IPA构建20成功；模拟器CI19在Xcode编译后触及20分钟步骤超时，没有运行结果，不能算通过或宣称实体已验收。用户自行装机测试。

- 2026-10-30 至31：Android发现页左上角新增选源入口，双平台选源列表显示原站网址及独立外部浏览器按钮；网络加载8秒后及失败页提供原站对照入口，本地EPUB不显示。先读 `docs/SOURCE_WEBSITE_HANDOFF_2026-10-30.md`。Timer不得改变原请求、缓存、429冷却、登录或当前书源；打开原站不附加应用Cookie。Flutter878通过／10可选跳过，版本仍1.1.0+78，尚未重新打包。

- 2026-10-28 后续封装已交付：Android `1.1.0+78`、iOS `1.1.0/build19`，先读 `docs/releases/1.1.0-read-latency.md`。下载目录 `C:/Users/30622/Downloads/LiteTale-1.1.0-20261028/`。独立源码提交7697d5b在专用构建分支，本地feature分支／HEAD／暂存区未改变；没有正式Release。源码快照860通过／10可选跳过，设备IPA构建与iOS模拟器8项均成功，APK签名／ZIP／16KiB对齐已验，未进行本轮实体装机或大陆网络A/B。以下“未打包／未提交”对应此前优化实施阶段。

- 2026-10-28 全书源加载优化：先读 `docs/LUNA_HANDOFF_READ_LATENCY_2026-10-28.md` 与 `docs/qa/read-latency-2026-10-28/INTEGRATION.md`。全部发现标签用 `DiscoveryTab` 保活，来源／revision 隔离；普通标签切换不重载，主动刷新有效。详情／历史一次交付完整 `SourceBookDetail`；共享请求独立取消，最后调用者离开才取消物理任务，旧清理不能碰新任务。幻梦可移除队列保留 16 项／350ms／9秒及429冷却；哔哩两页一个浏览器操作但仍需两个真实页面。详情与正文缓存均有界，轻书架额外一个活动目录保持 SortNum 正确；文库8／EPUB 沿用专用缓存。最终 Flutter 860 通过／10 可选跳过，31目标分析无问题；本轮版本仍1.1.0+77，未提交、打包或测实体大陆网络／iOS，不宣称所有来源瞬时首开。保留以下既有约定。

- 1.0.0修复构建73：先读 `docs/LUNA_HANDOFF_1.0.0_FIX5.md`、`docs/qa/wenku8-rate-limit-fix5-2026-10/INTEGRATION.md`。文库8429不是登录失效或CF验证，遵守Retry-After，不得换通道重试、清登录或轮换域名。书架合并刷新，只按需读当前组，网页首组响应复用10秒一次并按host/账号代数隔离，账号变化必须清种子。生产书架已用中央BrowserSession，不能接回独立CfBookshelfLoader的全分组预读。网页队列总30秒，过期任务不得迟到导航或影响新renderer；原生封面/正文/详情缓存锁分开，详情缓存预算含排队。687 Flutter通过/6可选跳过，17目标分析及35可执行Rust单元通过；旧Rust顶层测试缺夹具与日志初始化问题仍在，不得宣称全套通过。最终模拟器429/悬挂是受控夹具；真实公开阅读已通过，真实账号书架、实体ARM64和iOS未验收。保留以下构建72的EPUB优化。

- 1.0.0 修复构建72：先读 `docs/LUNA_HANDOFF_1.0.0_FIX4.md`、`docs/qa/epub-loading-fix4-2026-10/INTEGRATION.md` 和 `docs/releases/1.0.0-fix4.md`。本地 EPUB 章节投影不重复计算全ZIP摘要，但受管归档首次验证、CRC和资源限额不能移除。字体／章节投影／元数据／编码页图分别有界复用，缓存键覆盖书籍revision、实际字体和完整视口参数；原生池仍3项，元数据8项，两者不能混用预算。最后CSS阅读器关闭45秒后释放原生池，新owner可以复用旧owner已完成的共享工作，删书或重导入则不能沿用。Android11+快速无损WebP，旧系统PNG；quality0是无损编码投入，不是降画质。全量673通过／6可选联网跳过，最终装机、像素及计时口径见整合记录。不可宣称任意书瞬时首开、首帧统计、实体120Hz或iOS已完成。以下旧记录保留为历史。

- 1.0.0 修复构建71：先读 `docs/LUNA_HANDOFF_1.0.0_FIX3.md`、`docs/qa/epub-css-engine-2026-10/INTEGRATION.md` 和 `docs/releases/1.0.0-fix3.md`。用户明确取消本地 EPUB 仿真翻页；按 localEpub 书籍身份使用普通翻页，不修改全局 curl 偏好，在线书源保留原有曲面翻页。Android 分页使用离线 CSS/Foliate 内核，逐资源分派固定与流式版式；schema3/style8保存原ZIP，同原文件再导入保留身份与进度，旧缓存仍可读。DOM位置独立于旧字符偏移。字体兼容只改浏览器副本，不改原文件、全局字体或在线混淆配套字体。来源、许可、样本实测和未支持范围分别记录，不宣称全CSS／实体性能／iOS已验收。以下早期记录保留为历史。

- 本地最新交付为 `0.1.22+64`，工程/分支不变；GitHub仍是已发布0.1.21，本轮未commit/push/评论issue。先读 `docs/LUNA_HANDOFF_0.1.22.md`、`docs/qa/shelf-device-id-2026-10/INTEGRATION.md` 和 `docs/releases/0.1.22.md`。轻书架 `x-id` 必须统一由 `ShelfDeviceId.instance` 提供：首次UUID v4保存至独立安全存储键 `litetale.lns.deviceId` 后才发送，后续WebSocket、登录/刷新HTTP共用；退出登录/账号恢复只能处理原refresh键，不能删设备ID。缓存首次完整操作；调用方超时不能清掉仍执行的平台写入并重新生成ID。格式/存储异常安全失败，不发临时编号；等待须在原网络预算内，过期/退出后不能迟到连接或提交POST。441通过/7可选跳过，8目标分析无问题，匿名公开接口实际通过；最终APK三个进程首页正常，两次重启ID加密条目不变，原轻书架及文库8登录保留。不得把loopback/存储摘要检验写成设备明文header抓包或全部正文验收。以下0.1.21及更早保留为历史。

- 0.1.21 历史交付为 `0.1.21+63`，工程/分支不变。先读 `docs/LUNA_HANDOFF_0.1.21.md`、`docs/qa/bili-mobile-2026-10/INTEGRATION.md` 与 `docs/releases/0.1.21.md`。哔哩章节使用 `www.bilinovel.net` 普通移动页，不能恢复固定桌面章节入口；原 `bili:` ID不变，每页匹配 HTTPS origin/path/完整query，续页同origin、同书同章且无query。明确拒绝访问用 `BiliSiteAccessDenied`，不能给虚假验证成功入口或因硬拒绝换主机；可见页面拒绝时禁用确认。原站正文末尾明确加载失败通知用 `contentIncomplete`，有限等待后打开原站完成阅读要求，再确认完整正文。没有伪造广告/验证完成状态，不保证绕过原站限制。正常页面确认仍须平台flush及source/revision/生命周期检查后才写有界RAM快照，不能导出Cookie。428通过/7可选跳过、7目标分析和27项离线DOM通过；设备运行结果、受控夹具与真实广告/实体平板/120Hz的边界必须分别记录。以下0.1.20及更早内容保留为历史背景。

- 0.1.20 历史交付为 `0.1.20+62`，工程/分支不变。先读 `docs/LUNA_HANDOFF_0.1.20.md`、`docs/qa/bili-verification-2026-10/INTEGRATION.md` 与 `docs/releases/0.1.20.md`。实体平板 SeaBed 遇原站挑战，本轮新增 typed Bili 验证异常、有限自动等待、同源可见验证及确认后继续阅读；不得把模拟器无挑战成功当作实体设备解拦。Cookie 留在平台，只有 Bili 两个 renderer 开启第三方 Cookie，W8默认不变。确认页面必须匹配目标/完整查询且非挑战，flush及 source/revision/生命周期检查通过后才接纳。临时公开片段仅 RAM 2分钟/8项/2MiB，只有指定 www 移动/桌面 catalog 可互用。Reader/HtmlReader/NovelInfo 的旧成功和旧失败都要丢弃，不能只清 cause。最终417通过/7可选跳过、21目标分析与18项离线DOM通过；默认直连APK阅读/翻页及普通页面验证返回通过，实体挑战/ARM64/120Hz仍未验收。以下0.1.19及更早内容保留为历史背景。

- 0.1.19 历史交付为 `0.1.19+61`，仍在 `feat/expressive-sources`。先读 `docs/LUNA_HANDOFF_0.1.19.md`、`docs/qa/bili-site-2026-10/INTEGRATION.md` 和 `docs/releases/0.1.19.md`。哔哩接线为 `BiliSiteSource` + 独立 `BiliBrowserSession`，原域 `www.bilinovel.net` 移动页面，保留桌面结构兼容；`bili:` 书/卷/章 ID 不改。搜索提交原站真实表单，旧 window 的 pending 标记阻止读取推荐内容；后续分页必须核对目标 path 和完整 query，不能接纳导航提交前的旧页成功/错误。详情读取基本页和整本目录两个逻辑页面；移动目录明确验证失败时只回退一次到本站桌面目录，最多三次导航，不恢复逐卷 API 扇出。旧 `BiliApiSource` 仅留历史，不能重新注册其第三方 API。已移除维基文库、读书之家内置入口，保留用户数据和 ID→原站约束，明确手动导入的规则可保留。
- 首次网页组件 attach 使用操作剩余总预算，不能套已挂接平台命令的5秒上限；真正的 mode/load/JS 命令仍最长5秒。375项全量测试、冷启动相关复核和最终安装证据以0.1.19整合记录为准。
- 0.1.19 正文使用原站 `www.linovelib.com` 桌面阅读器；UA 保留设备实际 Chromium 版本，每次操作先复位移动模式，仅章节/目录回退改桌面模式，不能串入文库8。直接 Android WebView 几何对照发现不可见重复 `p` 是 absolute 且 bounds 宽高均0；只过滤这一定点条件，不删除所有 absolute、不按文本全局去重或重排。SeaBed/Re 样本提取分别102/26段，与原站实际绘制段落顺序相符，不能据此宣称全书库无误。`.csgo` 就绪猜测已撤掉；公开 zation.js 只是广告脚本。早期代理对照与最终默认网络须分别记录，APK 无代理配置，测试后恢复原代理状态。浏览器命令、排队和读取有超时，过期代数不能重置新 renderer，不导出 Cookie/账号。物理 ARM64/120Hz 性能仍未验收。以下 0.1.18 段落保留为历史基线，哔哩实现和内置来源以 0.1.19 记录为准。

- 0.1.18：滚动/分页 reader 用请求及书源会话代数拒绝旧成功和旧失败；SourceChapter 与字体成对保存。进度共用串行合并队列，正文不等待磁盘；本地历史仍沿用书源+书籍语义。规则源 ID 与原站关联在移除后保留，旧三源 ID 不迁移；只支持明确列出的 CSS/JSON 子集，外部规则不执行 JS/登录/加密。内置 SF 公开目录、读书之家、条件性维基文库；哔哩为独立 SourceId.bili / bili: 的试用入口，通过 lnovel.animes.garden 公共 API；实测接口正文有重复段落，未通过内容完整性验收，选源/推荐/详情必须保留提示，不能替换旧 lnovel.tw / lnv:。哔哩书名查找是公开榜单逐页匹配，不是全站搜索；分卷最多3并发，80卷/10000章/30s目录总预算，超限明确失败。不能把网络超时、上游502或模拟器截图写成在线恢复/120Hz达标。桥报告、实际在线失败与最终安装验证均在 optimization-2026-10 目录，优先以 INTEGRATION.md 为准。

- 最新工作分支 `feat/expressive-sources`，版本 `0.1.18+55`。全局优化先读 `docs/LUNA_HANDOFF_0.1.18.md`、`docs/qa/optimization-2026-10/INTEGRATION.md` 与 `docs/releases/0.1.18.md`；双书源历史先读 `docs/LUNA_HANDOFF_0.1.17.md`、`docs/API_STABILITY_REVIEW_0.1.17.md`，安装后验收见 `docs/qa/0.1.17/device-checks.md`；文库8持续加载背景见 `docs/LUNA_HANDOFF_0.1.16.md`。网页命令必须有超时，过期控制器用代数隔离重建，GET 不等待图片全部加载。其余工作优先读 `docs/releases/0.1.15.md`、`docs/LUNA_HANDOFF_0.1.15.md`、`docs/LUNA_HANDOFF_0.1.14.md` 和 `docs/BOOK_CURL_HANDOFF_0.0.19-dev.13.md`。平板横屏采用真正双页；`ReaderViewportLayout` 的尺寸、系统字号缩放与粗体必须同时用于分页和绘制，`ReaderPosition` 保留旋转锚点。阅读时不显示页码、时间或进度，`ReaderSystemUiScope` 按路由生命周期控制系统栏。第三源 `lnovel` / `lnv:` 公开免登录；搜索是有明确提示的目录逐页查找，不是站端全文搜索。Android SDK 已迁至 `D:\Codex-Migrated\Android\Sdk`。

- 0.1.17：文库8搜索使用同源真实 GBK 表单；搜索第一页允许省略 page=1，分页复用按查询隔离的真实下一页链接，不重复 POST。只有明确搜索间隔提示才等待最多10秒并重读一次 GET，持续限流有限失败。轻书架只读请求瞬时失败重连一次，每次总计20秒，登录/写入不重试；5xx不清凭据，只有明确认证失败才失效。刷新合并、账号代数隔离和凭据串行落盘必须保留。轻书架当前网络匿名 Hub 502，API根地址502/超时，不能把离线夹具通过当作在线正文恢复。

- 0.1.15 用户改为“我的 → 显示”，直接进入精简显示页；`SettingsPage` 保留类名作为兼容入口。只保留主题与纸张、字体、阅读显示和地区字形；阅读显示保留排版、阅读模式和仿真翻页效果，移除点击/音量键/章节边界/误返/亮屏等操作选项的 UI。不要恢复设置总页、更新/数据/语言/关于分组。关于、阅读统计与书源仍在“我的”独立进入。仅移除 UI，不删除本机偏好或后台实现；文库8沿用 0.1.14 已验收的同源会话路径。

- 设置实现位于 `lib/settings/`，首页原设置文件仅转导出。分组和操作参考 LightNovelReader 1.1.0（固定源码链接见 `docs/LNR_SETTINGS_REFERENCE_REVIEW.md`）；数据与更新必须调用 LiteTale 自有服务。快照采用 `.litetale` 版本化白名单，不兼容上游 `.lnr`，不携带账号/会话；两库在一个 SQLite 事务中恢复，媒体先写摘要路径，禁止覆盖或删除旧字体/纸张。阅读统计只计真实前台阅读并按书源区分；不要从旧进度虚构阅读时长。汉字变体选择地区字形，不转换正文。设置移植已完成；本轮修复记录见 0.1.11 字体、文库8和图标报告。
- 文库8镜像只支持 HTTPS 的 `wenku8.net` 或子域名根地址，与 WebView 登录 cookie 域保持一致；不能通过放宽 host 校验把原站会话转发给任意镜像。快照覆盖 reading 类别会替换全部书源本机历史和统计，确认文案必须明确，不得说只替换当前源。
- 0.1.13 用户要求“我的”及内部所有操作页的主卡片和操作行填满整行，不是只改入口页。`LeftAlignedScrollView/ListView/CustomScrollView` 默认没有内容宽度上限，仅保留手机/平板正常边距，滚动视口全宽；不要恢复居中或 720/760 dp 单侧窄列。范围包括全部设置子页、字体、数据、日志、统计、下载、关于、账户与登录。局部主题缩略图、图标、图例和验证码保留正常尺寸，两侧边距必须可以拖动。文库8首页逐个识别有效书链接/封面/同卡片书名，不依赖栏目位置；WebView 只返回最小 JSON 书目字段。公开原生 HTML 路径仍遇到 403，旧 Android 接口未返回有效读数据；不得把浏览器夹具通过或封面 200 当作全站 API 恢复。0.1.14 的同源网页备用覆盖详情、目录、正文、分类、排行及搜索；尚未验证的在线能力和仍走原生接口的功能必须单独说明。

- 0.1.11 稳定优先：轻书架混淆正文继续使用配套章节字体；普通 Unicode 章节标题单独使用阅读设置字体。未经独立字表验证的 CJK/GID 排序解码仅保存在 build/ 的 QA 实验中，不得写进生产。文库8的 WebView 备用流只读取已验证的配置同源页面最小字段，不回写网页登录 Cookie；持续 Cloudflare 拦截仍需明确说明，不能把 fixture 通过当作联网恢复。非紫色 launcher 资源从对应类型/尺寸的 iris PNG 仅重新配色，不能重画、缩放或改变 alpha。
- 0.1.14：首页“选择书源”直接打开 `SourceSettingsPage`；设置顺序为“显示、更新、关于”，用户要求移除整个“数据”分组，不能自行恢复。后台快照/日志实现及用户本机数据保留，没有批量删除文件。阅读统计入口仍在“我的”。验证码和登录错误独立；CAPTCHA 与登录 POST 固定同一传输/host，POST 不自动重试。浏览器 GET 串行、超时有上限，读取后转 about:blank；可见站点验证只能接纳配置同源正常页面，浏览器模式与登录标记按 host 保存。搜索/标签使用 GBK 查询编码，不按 UTF-8 解码遗留百分编码。测试截图只保存必要页面，不导出账号 DOM、密码、Cookie 或原始日志。
- 0.1.14 登录持久化要求正常页面 `ready && authenticated`，Android CookieManager flush 完成后才保存 host 标记；记住登录的 select 选择有效持久选项，不可赋予不存在的 value。确认同源 GET 重定向到 login.php 时启用该 host 的浏览器模式、清除标记并通知 AuthCubit，网络错误/挑战不清登录。列表标题只从同一卡片的同书号链接匹配；单本搜索重定向复用严格原始查询校验。最终 Flutter 229 通过、2 可选联网跳过；真实设备检查及 APK 摘要以 0.1.14 交付记录为准。

- `FontSettingsCubit` 分别保存全局与阅读字体，导入的 TTF／OTF 校验后以 SHA-256 文件名存入应用内部。阅读测量和绘制都必须使用 `ReaderLoaded.fontFamily`；源自加密章节的 `chapterFont` 优先于自定义阅读字体，不可覆盖成普通字体。换字体沿用 `ReaderPosition` 重排，不重新请求已加载正文。字体导入实测入口为 `tools/qa_font_import_android.py`，设备测试为 `integration_test/font_import_test.dart`。

- 旧动效记录可看 `docs/VENERA_COVER_HANDOFF_0.0.19-dev.5.md` 和 `docs/NOVELLA_MOTION_HANDOFF_0.0.19-dev.2.md`，仅作历史依据。dev.8 撤掉封面淡入、按压层、点击翻页动画和阅读菜单滑入；用户之后指定 dev.9 的所有全屏页面用左右水平覆盖转场，不用页面淡入淡出。弹窗和底部菜单不在该范围；不要误把旧封面/阅读器动效搬回。设备测试使用带版本保护的 `tools/test_android_motion.ps1`，不要让 Flutter drive 自动降级卸载已有应用。

- 主工程和唯一工作目录为 `D:\Projects\LiteTale`。C 盘旧工程内容已由用户手动清空，原目录可能仍作为空目录保留。
- 接手先读 `docs/LUNA_HANDOFF_0.0.18.md`，并检查 `git status`；本轮多书源实现保留在工作区。
- 用户要求一次只使用一个书源，设置里切换并分别保留账号登录；不得混合不同源的书架、搜索和历史。
- 用户明确禁止批量删除文件或目录。不得执行 `del /s`、`rd /s`、`rmdir /s`、`Remove-Item -Recurse`、`rm -rf`。确需删除时仅能一次删除一个明确路径的文件；需要批量删除则请用户手动处理。
- Android 构建入口为 `tools/build_android.ps1`。设备测试 fixture 不是用户真实账号的数据，不要据此声称受限接口已实测通过。
- 2026-09-11 迁移审查：C 盘 `C:\Users\30622\Documents\Codex\2026-08-31\x\work\wild-source` 中 Astra 的 60 个已修改或新增路径均已在本工程找到；D 盘包含后续正式版、品牌和 GitHub 发布修正。后续 Astra 工作只在 `D:\Projects\LiteTale` 进行，不要回到 C 盘旧目录编辑。
- Astra 后续只在 `D:\Projects\LiteTale` 工作；C 盘旧工程内容已不存在，不要尝试从 C 盘恢复或继续编辑。
