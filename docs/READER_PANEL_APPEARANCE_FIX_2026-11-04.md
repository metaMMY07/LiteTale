# v1.2.2 阅读面板颜色与拖动条修复

2026-11-04。用户反馈 iOS 深色阅读设置出现浅背景/白文字，Android 目录和设置顶部有两条横线，目录滚动有紫色色块。

## 修复范围

- 保留 v1.2.2 的整张原生 SwiftUI Form。UIKit sheet、表单 controller、hosting controller 和 SwiftUI colorScheme 均使用同一个配置；根背景和分组行背景用对应 traits 解析的系统语义色。iOS 16+ 隐藏 Form 的隐式滚动背景，避免窗口外观与应用外观相反时缓存浅色底。设置变更回复也会同步原生外观。
- Android 全局 BottomSheetTheme 已开启拖动条，而阅读面板内部又绘制了一条。只在这两个自带拖动条的入口显式关闭外层拖动条，并取消透明外层的投影；全局主题和其他面板不动。
- 目录 ListTile 原来把 selectedTileColor/Ink 画在外层 sheet 的 Material 上。现在每个可见章节行有随内容移动的局部 Material 和圆角裁剪，选中背景留在行内；目录关闭有色 overscroll 装饰，滚动控制器与选章返回逻辑保留。
- 不改变翻页、音量键、封面、书源会话、Android 主题配色或主毛玻璃底栏。

## 验证和打包

- 两个相关 Flutter 测试文件共 18 项通过；4 个变更 Dart 目标分析无问题。
- 增加真实 iOS 原生面板深/浅色截图亮度断言，同时检查 controller/hosting traits，不能用 Windows fallback 作为 iOS 颜色验收。模拟器检查结果与设备 Release 构建/交付将另行记录。
- 版本仍 1.2.2，Android 内部代码 90；修复包单独保存，不覆盖或删除旧包。

## 参考

- Apple `preferredColorScheme(_:)`：https://developer.apple.com/documentation/swiftui/view/preferredcolorscheme(_:)
- Flutter ListTile 对 Material/Ink 的绘制说明：https://api.flutter.dev/flutter/material/ListTile-class.html
- Flutter showModalBottomSheet 的 showDragHandle 与主题继承：https://api.flutter.dev/flutter/material/showModalBottomSheet.html

QA 记录目录：`build/qa/reader-panel-appearance-20261104/`。
