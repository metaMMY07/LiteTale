# 原站评论修复一（2026-11-01）

用户反馈：iOS 所有哔哩评论显示“哔哩页面跳转地址无效”，轻书架部分评论显示 HTTP 500。Android 共用相同传输，因此同时修复。

## 哔哩：客户端阻断了自己的评论路由

首次评论实现将 `BiliSiteSource.comments` 接入生产 `BiliBrowserSession.document`，却漏掉该 Session 及平台组件共用导航白名单中的 `/reviews_{book}_{page}.html`。之前真实联网测试直接使用 HTTP 适配器，不经过手机浏览器传输，未发现此遗漏。

- 仅增加正整数书号、正整数页码的 HTTPS 公开书评列表路由；保持固定站点、443 端口、无用户信息限制。此新增路由不接受额外 query 或 fragment。
- 不放开 `reviewshow_*`、登录或其他任意页面，不修改章节同书同章验证，不增加换域重试。
- 新回归从 `BiliSiteSource.comments → BiliBrowserSession.document → BrowserPort → 公开评论解析` 完整执行，覆盖 iOS/Android 及第二页；修复前两平台均复现截图同样错误，修复后通过。
- 真实浏览器 QA 沿用应用的 Dart Session 和生产 DOM 脚本，经 Node/Playwright 的独立临时移动浏览器读取真实网站，不走直接 HTTP。iOS UA 与 Android UA 下《文学少女》各 30 条、《SeaBed》各 3 条成功；原站移动响应没有启用分页，因此不虚构分页。结果仅保存公开计数、路由、时间，没有导出 Cookie、账号或安装标识。
- 上述是 Windows Chromium 的移动配置验证，不是 iPhone WebKit 或实体 Android 装机验收。

## 轻书架：业务 500 未经过既有重试

对照官方 `GetComments` 参数补齐 `Size: 10`。真实对照发现：部分书籍无论是否带此参数，服务端均返回 `Success=false, Status=500`；另外两本可返回 2/4 条评论。因此不能把缺少 Size 认定为所有 500 的原因，也不能认定原站整个服务已恢复。

传输层原来只重试建连/握手 5xx，成功建立的 SignalR 调用所携带的 500 在源适配器外层才转换为异常，绕过了重试。现仅对 `GetComments` 在既有重试范围内识别失败 envelope，最多等待 350ms 后重读一次。

- 仍遵守评论仓库 25 秒总预算，最后订阅者离开后关闭连接，退避期间离开不能迟到重连。
- 401 交还既有账号刷新流程，403/429 不在传输层重试；登录/写操作不增加重试。
- 持续 500 明确失败，不清登录、不缓存失败，不伪造空评论。刷新失败保留当前已加载内容的原有行为保持。
- 新增真实 loopback 测试覆盖短暂/持续 envelope 500、401/403/429、退避取消、401 一次令牌续期、500 不清凭据。

官方参数依据：[LightNovelShelf Flutter GetComments](https://github.com/LightNovelShelf/Flutter/blob/6105cef68c7a09abcf8ec5e80cc5d107f2418462/lib/data/api/api_client_comments.dart)。本轮没有读取用户真实轻书架账号；联网探针复用上一轮独立且先持久化的 QA 安装标识。

本轮全量 Flutter 931 项通过、14 项可选跳过；6 个目标文件静态分析无问题。真实移动浏览器配置两项通过，短暂/持续500与账号保留通过loopback测试。未连接实体设备，未运行本轮iOS模拟器验收。

构建与验证日志位于 `build/qa/source-comments-fix1-2026-11-01/`。上一轮已发 build80 / iOS22 不包含本轮修复。新测试包保持版本 1.1.1，Android build81；最终 iOS 构建号和交付结果见对应发布记录。
