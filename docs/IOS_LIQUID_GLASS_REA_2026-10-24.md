# iOS Liquid Glass 与哔哩分页修复

## 范围

- 哔哩章节读取位于 Android/iOS 共用的 Dart 浏览器会话中，两端一起修复。
- iOS 恢复交互式边缘返回；首页和“我的”均提供“书源与账号”入口。
- iOS 使用原生 UIKit 底部栏、玻璃按钮和分段控件，保留发现、书架、历史、我的四个业务入口。
- 保留 Android 的现有外观和行为，以及阅读、EPUB、账号与缓存的既有实现。

## REA 安装包证据

分析对象为 [Novella v2.6.0 官方 release](https://github.com/celia-sh/Novella/releases/tag/v2.6.0)，而非仅凭截图推断。

| 项目 | 证据 |
|---|---|
| IPA | `Novella-2.6.0-release.ipa`，29,979,710 字节 |
| IPA SHA256 | `e138a10f177386de28110061051e5842da3e139eb780e35a225e947f98378cc1` |
| 主二进制 SHA256 | `e359519151a1ca5af7527896f82c447b295285e498b413bf7c12a1fc8aafd056` |
| 本机 REA | 安装包库存、plist、Mach-O 识别；Windows 缺少 macOS 原生命令 |
| 云端 REA | `rea-agents@6.5.0 inspect-macho`，macOS/Xcode 26.2，成功 |
| 云端 evidence | `ev_d78345c5cb053d8f78acfaef8e12af7c50d1959b26c3bf6b97c9851af37464cc` |
| 原始报告 | `build/research/ios-glass-2026-10-24/rea-macos/` |

[独立 REA 分析运行](https://github.com/metaMMY07/LiteTale/actions/runs/40075238475)仅下载官方安装包并分析，不签名、不发布应用。

二进制导入与 Objective-C 元数据包含 `UIGlassEffect`、SwiftUI `GlassEffectContainer`、`UITabBarController`、`ExpoGlassEffect`。安装包包含 Hermes/React/Expo，当前发行版是 React Native/Expo；它与仓库保留的 Flutter 版本不能混为一谈。

静态证据与源码相互印证：

- [当前 NativeTabs](https://github.com/celia-sh/Novella/blob/9fa7f97a1f04e82153bd658685a0df329f4b9c9b/apps/mobile/src/app/%28tabs%29/_layout.tsx) 使用 `expo-router/native-tabs`，并采用 SF Symbols。
- [当前顶部入口](https://github.com/celia-sh/Novella/blob/9fa7f97a1f04e82153bd658685a0df329f4b9c9b/apps/mobile/src/components/discover-navigation.tsx) 使用原生 Stack toolbar。
- [Flutter 归档](https://github.com/celia-sh/Novella/tree/23934b7e7f86002a448613e27c1f1d1906d6d6ac/packages/adaptive_platform_ui)包含 UIKit 平台视图与原生 tab bar 实现。其替换 window 根控制器的方案不直接移植到 LiteTale。

这些是安装包静态分析和源码证据，不等同于对 Novella 做过真机动态跟踪。

## GitHub 方案取舍

| 项目 | 适用部分 | 取舍 |
|---|---|---|
| [adaptive_platform_ui](https://github.com/berkaycatak/adaptive_platform_ui) | 原生 UIKit 控件与 Flutter 桥接 | 对照 Novella Flutter 归档理解容器与生命周期 |
| [native_liquid_glass](https://github.com/tienanh306201z/native_liquid_glass) | 原生 tab controller、平台视图、系统玻璃材质 | 最新版要求较新的 Flutter；仅参考公开桥接方式，避免同时升级整个 Flutter 工具链 |
| [Apple Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) | 系统材质、标准控件、可访问性降级 | 使用系统控件，iOS 26 获得原生材质，旧系统保留可用控件 |

LiteTale 的 `AppleGlassPlugin.swift` 使用子控制器包含关系，不替换 Flutter 根控制器，不引入整个第三方 UI 框架。参考实现的 MIT 许可保存在 `third_party/licenses/native_liquid_glass.txt`。

## 实现要点

1. 原生 `UITabBarController` 与 Flutter 当前 tab 双向同步，防止程序设置索引导致回调循环；iPad 保持底部栏。
2. iOS 26 顶部按钮采用 `UIButton.Configuration.glass()`；分段栏采用 `UISegmentedControl`。保留原生选择、按压、材质和辅助功能行为。
3. 按视图编号隔离 MethodChannel，组件销毁时移除 handler。新页面或弹窗出现时隐藏首页原生控件，避免浮在阅读内容上方。
4. iOS 使用 `CupertinoPageTransitionsBuilder`；测试包含拖动途中取消和完成返回。Android 原转场保持。
5. iOS 默认界面采用系统字体和更适合手机的封面密度，用户导入的 Flutter 界面字体仍经既有入口应用。阅读字体与源站防混淆字体逻辑保持。
6. 哔哩旧的 8 页硬限制改为 64 页安全上限，保留同章/同站校验、循环检测、30 秒总预算与正文大小限制，不跨章读取，也不绕过原站验证或广告授权。

## 验证

- 目标测试 42 项通过：iOS 工具栏入口、交互式返回、手机/iPad“我的”全宽布局、Android 转场与布局、网格、哔哩长章节/循环/超时/跨站保护；随后新增系统字体检查，5 项 iOS 专项验证全部通过。
- 新增系统字体检查后的完整 Flutter 回归 700 项通过；相关文件静态分析无问题。
- [iOS 构建 3](https://github.com/metaMMY07/LiteTale/actions/runs/40076810298)成功通过原生 Swift、Rust 和设备 Release 编译。系统字体与主题渐变细化将包含在后续测试包。
- Android 1.0.0 build 74 的 arm64/x86_64 Release 编译成功。
- 当前没有 iPhone/iPad 的直接控制通道，最终材质观感、原站真实章节和触摸响应需要使用新安装包在真机确认。
