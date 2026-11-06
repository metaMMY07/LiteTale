# 图片预览动效研究

参考物是用户提供的微信录屏，以及从 [微信官网](https://weixin.qq.com/) 下载的 [Android 8.0.80 arm64 安装包](https://dldir1v6.qq.com/weixin/android/weixin8080android3220_0x28005032_arm64.apk)。APK 的 SHA-256 为 `9d9b6c516e8e07e437c81485fde21fe13ce4f61b37d19e793fff40c71be39c0e`。使用本机 REA 6.8.0 和 JADX 0.7.1 查看类与方法。整包方法反编译超时后，保留原始 DEX 字节，将含目标类的 `classes3.dex` 和 `classes10.dex` 分别作为分析输入。

| 观察 | REA 证据 |
| --- | --- |
| `ImageGalleryUI` 持有 `TouchMediaPreviewLayout`。`finishAfterTransition` 会按启动参数选择共享元素退场。 | `ev_370c3b4280b81b2f4ced92220ef1fab26dff2fbb0d0f64a3fb2c7f45d14a82d2`、`ev_e29b0e935fb6b7d3fc309446659c1a45c46217f53aabbfd372683ef915d126e0` |
| `TouchMediaPreviewLayout.dispatchTouchEvent` 分开处理单指移动与多指缩放，并记录速度。`DragExitCropLayout.onScroll` 在允许下拖时，按图像中心的位移同时调整缩放和背景透明度。 | `ev_5a27bfd4f5ae40250bba9c901206e193fd6f70138206b40c09d4f93416e9f206`、`ev_3d902f7c8e754e13f658796720b19a6541d059eb43e80c097063410e4797d718` |
| `CropLayout.O` 先取消上一个动画，读取此刻的矩阵、缩放和图像中心，再用一个 300 ms 的减速动画更新缩放与双轴位置。 | `ev_57c42e7f61ed3e0f053739592860fc50ac80879c15d4d820b673597f750461fc` |

录屏可见原位放大、背景变暗、拖动时露出底层、短拖回弹及松手后返回原位。安装包证据来自 Android 静态分析。iOS 的可见效果来自录屏，iOS 内部实现和原版的手势阈值未经验证。

LiteTale 以插图的实际显示矩形为起点，使用透明路由保留底层阅读画面。预览优先复用已显示的图片。单指下拖触发后，位移、缩放和黑底透明度同帧更新；松手从当前画面承接速度，短拖回到适屏位置，超过距离或甩动阈值则回到原插图。手势阈值按屏幕短边调整，缩放后的平移由 PhotoView 处理。减少动态效果开启时采用淡入淡出。iOS 预览控件独立使用深色玻璃和白色图标。

运行了图片预览和阅读点击区域共 11 项 Flutter 检查，覆盖原位展开、短拖、长拖松手连续性、双击缩放、平移、图外关闭、保存和导出。设备上的玻璃外观与拖动手感待真机确认。
