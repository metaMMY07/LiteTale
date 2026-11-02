# 1.2.0：iOS详情胶囊与Android旧版配色

2026-11-02。Android内部构建85，iOS由设备工作流生成新构建。包含此前84的六源封面首显渐变；84 APK不包含本轮配色恢复，iOS26不包含本轮胶囊。

## iOS

用户追加授权仅调整详情中的分类标签。`AppChip`增加可选capsule参数，只在详情标签启用；Flutter使用StadiumBorder裁剪和命中轮廓，标签留白调整为横16/纵8。原生玻璃surface的宿主与UIVisualEffectView都按当前高度的一半设置圆弧，避免外层裁剪为胶囊而玻璃仍按固定20圆角计算，造成两端尖瘪。其他卡片仍沿用既有轮廓，详情的头部、按钮、目录和信息不重做。

## Android

1.0.0原始六色种子仍为6750A4、3864A0、AD416B、995C22、006B65、526B50，主题生成也一直保留系统动态色。前一次只恢复ThemeData色阶，没有恢复新组件内部的实际取色：

- 底栏从secondaryContainer恢复1.0.0的浅色primary/深色primaryContainer，对应图标恢复onPrimary/onPrimaryContainer。
- 底栏毛玻璃仍保留，恢复旧版底色角色、72%透明度及分界线，几何、位置、高度和动画不改。
- 新控件调用的materialSurface不再额外叠加onSurface灰色，直接使用旧调色板原始色阶。新卡片、选择栏形状保留。
- 导入/共享设置中的ios-*色名在Android转为对应旧版预设；原本六色、自定义颜色和system保持。iOS颜色选择与原生色解析不改，加载偏好不额外写盘。

基线是工作区HEAD `7f5cb216a6cb7dce43e4d1ab94787d5c83355321`（1.0.0+73），并核对1.0.0正式构建提交c004b42的相同取色。不是把Android改为iOS调色板。

## 必要验证与边界

13项相关Flutter检查通过，包括前一轮六源封面/缓存/离屏首显、详情继续阅读与空字段，以及新增的iOS标签半圆路径/点击、Android两种外观的真实导航像素颜色、系统动态色和导入偏好兼容。7目标静态分析无问题；Swift由iOS Release云端编译核验。

按用户要求不跑全量或实体测试。Flutter测试中的原生玻璃为fallback，不能当成iPhone玻璃光学效果验收。用户装机确认最终观感。标签/配色未改变原站请求、书源、账号或阅读进度。

日志先保存在 `build/qa/cover-fade-fix2-20261102/palette-capsule-tests-pass.log` 与 `palette-capsule-analyze-final.log`，构建/交付记录位于 `build/qa/palette-capsule-20261102/`。新包复用前一轮封面实现，不能将84/26说成包含此追加调整。
