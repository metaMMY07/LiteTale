# iOS 1.1.0 书源导入实现与验收

研究依据：`docs/research/LEGADO_E_SOURCE_IMPORT_2026-10-25.md`，固定源码与 REA APK 反编译证据均在该报告中。本文描述重建的有限兼容层，未复制 Android Java / Rhino 执行环境。

## 实现

- `source_import_file.dart`：Files 使用 public.json / public.plain-text / public.data 类型标识，随后做最多 2 MiB 的流式读取、UTF-8 与 BOM 处理。允许通用文件类型是为兼容下载提供者的标签，不能跳过内容校验。
- `legado_compatibility.dart`：声明式规则转为内部 schema 1。URL 摘要身份、CSS 链、零基/负索引、自身文本、结果组合和受限替换均离线解析。不执行脚本；不支持的必需规则拒绝导入，可选元数据的未支持部分明确提示。
- `rule_source_registry.dart` / 导入页：预览、单项兼容错误、选择、替换/副本、串行保存。iOS 按已保存 importKey 复用身份，规则简化、改名仍不切断旧书籍关联；站点变更受原有 origin pin 约束。Android 继续使用旧导入入口。
- `rule_source_engine.dart`：接入兼容选择器与字段，文本先转义为段落再清理 HTML。目录与正文使用现有同源分页、环路与资源/总时限保护；不把“下一章”当“下一页”。
- `scoped_rule_transport.dart`：仅扩展 iOS 源使用，每个适配器独立内存 Cookie，检查域、路径、Secure、过期和容量；不分享内置会话、不持久化、不自动重定向；429 后遵守 Retry-After。超时主动关闭客户端，响应有字节上限。
- 首页：仅搜索书源提供搜索入口，避免空白推荐页。

## 样本与限制

原始“幻梦轻小说.json”SHA-256：`e89cd49af668a62c6ea76a7494b17f320a2fd2e380e874634a56d9fb9fa28a9b`。字节夹具在 `test/fixtures/huanmeng-source.json`；跨平台 UI / 模拟器测试使用等价 JSON 常量，不作为应用资产发布。

`ruleContent` 的 `@text` 已丢弃图片标签，后接 img 替换无实际效果；因此本规则文字阅读不标称支持插图。详情 kind 的 List/String 类型疑点不映射阅读状态。checkKeyWord / imageStyle 作为元数据提示，不发送其调试地址。

Windows 实际 GET 的 403 记录沿用研究证据，没有反复请求、换域或声称原站已恢复。离线夹具内容为人工短句，不是该站真实章节抓取。

## 测试方式

本地真实 file_selector_ios Dart 插件与 Pigeon codec 验证文件类型参数、取消；组件测试从本地文件操作经过预览到保存和重载。独立兼容层测试覆盖样本、选择/清理语义、危险脚本/正则拒绝和资源限额；引擎夹具覆盖两页目录、两页正文及跨站/循环拒绝；loopback HTTP 测试覆盖 Cookie 隔离、删除、路径、Secure、429、响应上限与超时。最终计数见交付目录 validation.json。

GitHub iOS acceptance 另使用原生 UIDocumentPicker 和 file_selector 插件打开系统文件界面，保存截图，由仅模拟器编译的驱动提交应用内样本 URL，再验证导入、保存、重载和取消。驱动不会编入设备 IPA；它验证插件链路，不替代用户在实体设备 Files / iCloud 中挑选文件的手工验收。原有玻璃/主题/普通翻页/Apple Books 验收继续执行。
