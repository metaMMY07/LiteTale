# Android 阅读面板半屏/全屏切换

2026-11-04。用户确认 iOS 的表现符合要求，本轮只修改 Android 交互并封装 APK。

- 点目录先打开半屏（可用高度的0.5）；在横条区域轻扫上推，松手后自动展开到可用高度1.0，不用持续拖完整段距离。全屏下扫回半屏，半屏下扫关闭，关闭后仍是原阅读页。
- Android 阅读设置复用同样规则。横竖屏均从半屏开始；主导航、主题配色、字体和选章行为不改。
- 横条仍直接控制同一个 DraggableScrollableController，章节已滚到中段时也能拉起，不要求列表先回顶部。松手结合末段速度与拖动方向选择目标档位；250ms 的 drawer 曲线从当前显示高度启动，后续手势可中断。减少动态效果时直达目标。
- 章节列表使用 SDK 的 snap，保留半屏、全屏两个停靠高度；最小高度只用于关闭。程序调用 jumpTo/animateTo 不会自动触发 SDK snap，因此横条有独立松手收尾。参考固定本机 Flutter3.29.3实现与官方文档：https://api.flutter.dev/flutter/widgets/DraggableScrollableSheet/snap.html。
- `snapToPages` 仅在 Android 调用方开启。没有修改 iOS 原生 Swift、配色或系统 sheet，也不构建新的 IPA。

## 验证与交付

- 两个相关 Flutter 文件共18项通过，包含目录和设置的40px短扫自动全屏、下扫回半屏、动画中反向接管、原章节offset不变、半屏下扫关闭后阅读页保留。
- 4个相关 Dart 目标分析无问题。原生实体手感由用户最终检查，不把 Widget 手势测试说成实体平板验收。
- 版本仍1.2.2，Android内部代码92。新包单独存放，旧包保留；不批量删除文件。
- QA：`build/qa/android-sheet-snap-20261104/`。打包身份及摘要在交付记录中。
