# LiteTale v1.2.2 阅读菜单修复

2026-11-03。按用户要求尽快交付，版本 1.2.2，Android 内部代码 89，iOS 使用 CI 内部序号；旧安装包保留。

## 参考与边界

- 使用 REA 6.8.0 核验 Novella 2.7.0 官方 IPA（SHA256 `9948a1474ae7357b1541a10e53bd7071f0caf53542b6939bd1717c4702142ea7`）和 Yomiru 1.6.0 APK（SHA256 `a5da1791c1bca3281e831eedf0ff524786475208d168479e93ea11148de2ef14`）。证据在 `build/research/reader-menu-2026-11-03/rea-evidence.json`。
- Novella 固定公开源码 `bedd62c5a20aa80e9bf922b33ea12887d991aa8a`：`apps/mobile/src/app/_layout.tsx` 的 reader settings / chapters 使用 formSheet、0.5/1 两档、原生 grabber；`native-grouped-list-platform.tsx` 用 SwiftUI Host/Form/List，文本与控件属于同一原生层；`native-setting-controls.tsx` 保留草稿，编辑结束才提交。
- Yomiru 固定公开源码 `1c0e43f3d1c70b9a5126c4dbda529be3b92a18be`：`source/lib/widgets/reader_typography_sheet.dart` 区分 preview/commit，分组列表和更多排版设置。模拟器本轮启动成功，但首页网络失败，未进入阅读菜单；不把它写成动态菜单验收，也没有重试不支持的 unified Dart AOT 反编译。
- Windows 没有 iOS 运行环境；本轮新增专门的离线 iOS 26 模拟器 smoke 流程，截图来自真正的原生窗体，不以 Windows fallback 当 UIKit 验收。
- 官方原理参考：Apple `UISheetPresentationController` 的 detents / 滚动展开协作，以及 Flutter iOS platform-view 分层机制。采用系统 API 重新适配，不复制两个项目的业务设置或请求代码。

## 改动

- 收藏按钮固定 56×56，图标在玻璃背景的中心。书评移至详情右上角，与下载并列，仅图标并保留辅助功能标签和各源能力条件。
- iOS 设置不再把多张独立 UISlider 平台视图嵌进 Flutter 的裁剪长列表。整个 Form 的标签、图标、分隔和滑杆在一个原生 SwiftUI/UIHostingController 层内；原生 Slider 保留 iOS 26 玻璃拖动头，使用语义颜色，支持大字体换行。
- 保留 LiteTale 字号、行高、段间距、四侧留白、阅读模式、音量翻页、独立纸张颜色/文字颜色、背景图片/浓度、滚动速度/间隔设置。通过原有 cubit 保存，滑杆松手才重排；类型/范围/选择验证，重复保存隔离。相册和颜色选择由当前原生控制器展示。
- iOS 阅读设置与目录使用系统中档/全档 sheet，滚动和拉起交给同一系统滚动层。Flutter 保留一个对应的模态路由，暂停底层阅读手势/音量监听；系统下滑、关闭按钮和返回均只关闭该面板。旧 session 的迟到事件不能关闭新面板。
- Android 目录与阅读设置用 Material You。目录统一为懒加载列表，使用 DraggableScrollableSheet 提供的同一个 ScrollController，修复之前两个控制器互不相连导致的拉起/滚动不连贯。章节选择等面板关闭后才加载，不弹出阅读页。
- “我的 → 显示 → 阅读显示”也复用同一 iOS 原生表单，避免只修阅读弹层。
- 不改已认可的普通翻页节奏、音量原生策略、Android 毛玻璃主导航、封面过渡或书源/账号数据。iOS 本地 EPUB 仍交 Apple Books。

## 验证口径

只执行针对性检查与必要平台构建。具体结果和包身份写入 `build/qa/reader-menu-fix-20261103/`。iOS 原生截图与模拟器交互不等于实体滑动手感验收；最终手感由用户装机检查。
