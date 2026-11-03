# LiteTale v1.2.0：拖动跟随、前后台恢复及iOS音量键

2026-11-03。用户确认点击翻页节奏可保留；本轮仍交付v1.2.0，文件名不加build。Android内部87，iOS内部标识由设备工作流生成。

## 已确认的问题和修复

1. `ReaderCoverView`只在非resumed状态重建，后台时将手势回调设为null，恢复却不重建。旧包的空闲恢复/拖动中断恢复均在无点击的首次滑动测试复现失败；修复为每次生命周期变化都更新状态，离开时清除拖动、动画及排队状态，恢复立即挂接手势。额外检查初次挂载在inactive时的首滑。
2. 拖动松手与点击共用easeInOutCubic，使已有速度先减慢，再重新加速。旧包的速度连续性检查复现失败。拖动现用Flutter3.29.3 PageScrollPhysics的同一弹簧与像素容差，传入真实松手速度；到目标边界即释放输入，避免不可见超冲继续占用手势。点击和音量触发的360ms曲线不变，纸张像素对齐、无页间阴影仍保留。
3. iOS旧代码用`setValue(animated:)`加合成valueChanged回设音量，没有验证设备实际音量，250ms后迟到的回设KVO还可能被判为反向翻页。新代码采用MPVolumeView slider的value setter并有限核对实际音量；typed KVO与回设任务按监听代数隔离，回到基线的通知始终不产生按键，保留连续真实变化。
4. 音量0/1附近只保留0.0001余量，不再预先变动一个完整硬件音量档。退出先回设原音量，控件保留一帧周期供系统提交；旧会话延后清理不会关闭新会话。耳机插拔按新输出路由建立基线，音频中断时不派发按键；已匹配的音频类别不反复设置。
5. 音量回设若确实不可用则停止接管并给出可重开的提示，不能把持续改变音量伪装为成功翻页。弹窗、后台、退出/关闭偏好仍交回系统音量。

## 参考与实现边界

- Flutter固定SDK：[PageScrollPhysics](https://github.com/flutter/flutter/blob/3.29.3/packages/flutter/lib/src/widgets/page_view.dart)、[ScrollPhysics](https://github.com/flutter/flutter/blob/3.29.3/packages/flutter/lib/src/widgets/scroll_physics.dart)。直接调用SDK已有实现，不添加动画依赖或凭空调参。
- [Apple outputVolume](https://developer.apple.com/documentation/avfaudio/avaudiosession/outputvolume)：iOS提供的是可观察的系统音量，并非阅读器可直接消费的硬件按键；[MPVolumeView](https://developer.apple.com/documentation/mediaplayer/mpvolumeview)提供系统音量控件。[AVCaptureEventInteraction](https://developer.apple.com/documentation/avkit/avcaptureeventinteraction)限实际相机拍摄，不能拿来给阅读器冒充按键接管。
- 对照原作者实现：[flutter_volume_controller VolumeController](https://github.com/yosemiteyss/flutter_volume_controller/blob/main/ios/flutter_volume_controller/Sources/flutter_volume_controller/VolumeController.swift)、[slider value setter](https://github.com/yosemiteyss/flutter_volume_controller/blob/main/ios/flutter_volume_controller/Sources/flutter_volume_controller/Extensions.swift)；旧JPSVolumeButtonHandler核对微小边界余量及基线回调过滤，未引入其已弃用MPMusicPlayerController音量写入。LiteTale桥接、生命周期、回读及错误处理为本工程实现。
- iOS仍是观察变化后回设的兼容办法，不能声称系统绝无瞬时变化或在所有耳机/系统版本上都能截获每次快速反向按键。首次恢复、点击、拖动与Dart事件转发可用自动检查；真实硬件音量、HUD、蓝牙及后台音乐需iPhone/iPad确认。没有新增相机权限、后台录音或私有按键接口。

## 验证与交付记录

23项不同的相关Flutter检查通过（21项翻页/音量开关/错误提示及路由生命周期，另外2项冷挂载和快速甩动边界）；4目标分析清洁。iOS构建额外运行生产ReaderVolumeState的6组纯Swift事件序列，验证迟到/重复回设、连续方向、0/1边界、缺失old值及换输出路由；它们不模拟MPVolumeView硬件，不能当作真机音量验收。设备Release编译、包校验及具体产物见最终发布说明。用户要求不跑全量或模拟器全套。

本机原HEAD/分支/暂存区保留，既有书源/登录、封面、平台配色、详情、页脚与Apple Books不改。本轮QA位于build/qa/reader-gesture-fix-20261103。
