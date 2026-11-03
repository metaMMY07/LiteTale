# LiteTale v1.2.1：阅读设置、跳页及连续滑动

2026-11-03。接续 v1.2.0 手势/音量修复；用户认可点击和音量键，本轮不重新调整两者或音量原生桥接。

## 交互和界面

- 分页阅读菜单换浮动返回、标题、目录/设置胶囊；Android 使用现有 Material You surface/主题强调色，保留应用其他页面及毛玻璃底栏。滚动阅读的顶部操作和设置也沿用统一入口。
- `ReaderSettingsPanel` 替代两套旧阅读设置，iOS 为圆润分组、可从约半屏上拉的面板，Android 为 Material You 分组。保留 LiteTale 自有字号、行高、段间距、四边距、阅读方式、音量键、外观/图片与滚动配置；没有搬入参考软件的标题选项。全局“阅读显示”使用同一面板。
- 字号/间距的拖动先预览数值，松手一次保存及重排，不逐帧读写数据库/重新分页。底部书页滑杆同样仅松手跳转；章节或排版变化取消旧拖动。
- 在线滑杆明确标“本章”，使用已排版的章节页数；横屏跳到相应双页。Android EPUB 取所属完整章节页数，在有界预读窗口之外也可定位，保留本地章节进度及锚点；不会把64页缓存窗口谎称整书总页数。iOS本地EPUB仍使用Apple Books，不在此处替换。

## 连续滑动

`ReaderCoverView` 不再把拖动距离硬截为一页。经过完整页边界后立即提交已越过页，将剩余拖动距离交给下一张纸；新的滑动可抓住未完成的收尾继续翻。分页回调的旧索引回显不能取消下一段拖动，最后回显确认后清除记录，外部滑杆跳页仍生效。短拖取消、反向拖动、退出/后台清理和仅提交实际经过的完整页面保留。点击/音量360ms曲线、纸张不透明/页间无竖线、时间页码沿用v1.2.0。Android独立仿真翻页不在本轮重做。

## iOS 原生滑杆及配色追加

用户指出旧圆形滑块及预览偏粉。本轮 AppSlider 的 iOS 真机路径改用现有 AppleGlass 原生桥接下的 UISlider；iOS26由系统提供液态玻璃拖动头和伸展反馈，不设置自制thumb图片/颜色。横向拖动和点击归原生控件，纵向仍交给设置列表/面板。开始、连续值、结束、取消分别返回，VoiceOver调整也能完成一次保存；范围/章节改变拒绝旧事件；Flutter数值回显不打断正在跟踪的原生控件。

- [Apple WWDC25 UIKit 新设计](https://developer.apple.com/videos/play/wwdc2025/284/)：原生控件拖动头和滑杆的系统反馈。
- [UISlider](https://developer.apple.com/documentation/uikit/uislider)、[sliderStyle](https://developer.apple.com/documentation/uikit/uislider/sliderstyle)。采用公开 UIKit 默认风格，不依赖私有API。
- 对照原作者 [native_liquid_glass](https://github.com/tienanh306201z/native_liquid_glass) 的平台视图、横向/点击手势、更新与遮挡处理；沿用本工程现有桥接，没有添加整个外部组件库。控件和状态为本工程实现，原有MIT归属保留。

iOS背景/卡片采用UIKit解析的系统分组色，正文/辅助文字保持系统黑白灰，默认systemBlue；可选择其他iOS系统强调色。iOS也有systemPink，但不使用Material种子色派生的粉色文字和背景。修复已有自定义RGB强调色重启后被映射回蓝色的问题；Android色盘不变。QA预览改用真实iosGlassTheme，先前Material粉色seed测试预览不是最终iOS配色。Windows widget测试只能渲染UIKit的Flutter后备画面，不能把预览中的圆形fallback或策略测试当作原生玻璃真机验收。

## 验证与封装

55项相关Flutter检查通过，16目标分析清洁；包括不停手跨页、前一次收尾未完成就再次拖动、父索引回显、短拖/反向/后台、滑杆预览/取消/单页/章节变化、横屏及完整EPUB章节定位、原生事件阶段、系统色与自选色保留。Xcode设备Release编译和两端产物核对以发布说明为准，仍由用户实体测试手感和原生玻璃外观。没有重跑全量/模拟器全套。

版本1.2.1，Android内部88；iOS内部由设备CI生成。使用独立临时git index/构建提交，本地feature分支、HEAD、暂存区不变；旧包保留，没有批量删除。QA：`build/qa/reader-1.2.1-20261103/`。
