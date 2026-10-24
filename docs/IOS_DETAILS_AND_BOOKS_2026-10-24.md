# iOS 细节修复与 Apple 图书交接

此记录接续 IOS_GLASS_BUILD_2026-10-24.md；旧 iOS build 6/8 不是本轮最终交付。

## 当前范围

用户在六项反馈后改为：iOS 本地 EPUB 交给 Apple“图书”处理排版。Android 保留现有 CSS 阅读器；网络小说继续使用应用内阅读、仿真翻页与音量键。

- 系统启动图、应用内启动页和文库8登录图统一为已确认的紫色书本图案。用户后续确认的蓝发人物来自应用内 startup.png；其实际引用及包内资源均已替换。iOS AppIcon 的有效清单引用 Icon.png，旧的未引用 Icon-App 文件不能作为当前桌面图标证据。
- iOS 本地单本导入完成后弹出系统文档分享菜单，用户选“图书”。本地书库点击书籍、详情/历史阅读入口同样转交。分享的是校验后的 EPUB 原件，取消分享不会移除书籍。
- 书封与标题区域统一尺寸、字号和两行标题占位；轻书架、轻小说百科、哔哩首页增加逐页续载、去重与失败重试，切源后的旧请求不会回填。
- iOS 设置/“我的”移除叠加分隔线；选项组与分类菜单使用 UIKit 玻璃材质/菜单。
- 主题切换冻结整窗像素后进行 680 ms 圆形揭露，兼顾原生控件与 Flutter 正文，遵循系统减少动态效果设置。
- 用户后续要求移除 iOS 仿真翻页：在线阅读固定走普通 PageView，阅读设置和菜单中的仿真开关隐藏，已保存的 curl 偏好不再影响 iOS。旧纹理网格原型移至 docs/research/ios-curl-mesh-retired.dart.txt；Android PTQ 仿真翻页不变。硬件翻页保留有界缓冲与失效清理。

## iOS 全界面统一（后续追加范围）

- 用户明确只先统一 iOS，Android 不随此轮界面/配色/翻页变动。Android 的 Material You 主题及原多边形加载组件与上一构建内容相同，适配组件在 Android 分支返回原控件。
- iOS 使用普通圆环加载，颜色跟随当前界面强调色；减少动态效果时保持静态加载标记。
- 首页排行、全部书源分类/排行、书架分组、历史、我的和内部卡片共用原生 UIKit 玻璃层。iOS 控件经平台适配层使用 Cupertino 按钮、表单、开关、滑块、选择、对话框和底部弹层；菜单及分段选择继续用 UIKit。
- 配色不再从 Material seed 派生。启动时直接向 UIKit 查询两种外观的语义颜色和系统强调色；默认蓝色，提供九种 iOS 系统颜色选择。原六个预设映射到相应 iOS 颜色，不删除 Android 偏好。

## 验证与边界

- 本轮全量 Flutter：708 项通过、8 项按环境跳过；新增平台控件、表单校验、长标签滚动及配色回归在定向 17 项中通过。62 个变更 Dart/集成测试目标无错误或警告。最终云端状态见 validation.json。
- iOS 编译与最终模拟器结果：见本轮 docs/qa/ios-details-2026-10-24/validation.json，待云端验证后更新。
- 历史纹理翻页原型曾检查真实 iOS 模拟器截图；该功能现已按用户要求移除。首次主题快照方案在视觉检查发现只冻结了部分内容，已改为 UIKit 整窗像素捕获并增加像素断言，不能把第一次测试通过视为最终验收。
- iOS WebKit 自绘 EPUB 尝试未通过原书文字绘制验收；用户改用图书后，它已撤出应用目标。研究原型与失败用例保留在 docs/research/ios-webkit-*.txt，避免误称完整 CSS 已移植。
- iOS 没有向应用开放静默导入其他应用书库的接口；当前交接采用系统文档分享活动，需要用户选“图书”。图书内的字体、进度和阅读操作由图书管理。
- 模拟器可验证文件转交菜单、取消与文件保留；Apple 图书实际接收和硬件音量键仍需 iPhone/iPad 验收。

## 参考

- [Apple UIActivityViewController](https://developer.apple.com/documentation/uikit/uiactivityviewcontroller)
- [Apple openInIBooks 活动类型](https://developer.apple.com/documentation/uikit/uiactivity/activitytype-swift.struct/openinibooks)
- [EPUB 标准类型 org.idpf.epub-container](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/epub)
- 主题整窗捕获采用与 Flutter integration_test iOS 截图相同的公开 UIGraphicsImageRenderer/drawHierarchy 方法。

## 工作区

本地工作区 D:/Projects/LiteTale；使用独立 Git index 在 build/ios-preview-2026-10-24 构建分支提交。未改动用户已有 AGENTS.md 或真实暂存区，未创建发布、未清除数据或重装用户设备。
