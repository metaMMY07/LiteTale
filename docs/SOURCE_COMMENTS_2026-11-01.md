# 原站评论接入（2026-11-01）

用户要求内置书源原有的评论直接在 Flutter 页面阅读。此次为只读评论功能，不新增发布、点赞或删除评论；评论不参与详情、首页和正文的加载链。

## 六个内置来源

| 来源 | 实现与当前验证结果 |
| --- | --- |
| 文库8 | 保留原生接口，补充既有同源 BrowserSession 的 reviews 提取；复用现有账号、配置镜像、GBK 和 429 冷却。当前网络原生 HTTP 仍返回 403；新的网页提取用本地 Chromium 夹具执行通过，没有宣称真实账号评论已装机验证。 |
| 轻书架 | 官方 `GetComments(Type=Book, Id, Page)`，从 Users / Commentaries / Data 还原作者、正文、回复和回复目标。生产沿用自己的 ShelfSession 和 ShelfDeviceId，网络问题不清登录。真实匿名请求成功，样本 2 条评论。 |
| 轻小说百科 | 读取同一本书 `main article` 评论区，保留原顺序和被引用内容；该页当前一次嵌入全部评论，不虚构第二页。真实样本 19 条，包含引用。 |
| 哔哩轻小说 | 通过既有 BiliSiteSource / BiliBrowserSession，读取移动站 `reviews_{book}_{page}.html`。真实公开样本 30 条。仅接纳同书实际可见的分页链接；部分响应把分页栏注释掉，不能把被禁用的 HTML 当成真实下一页。原站列表可能只有长评摘要，完整长评和回复会要求原站登录，明确提示并保留剧透标志，没有绕过登录或拿别站评论替代。 |
| 幻梦轻小说 | 两本公开书籍页（8676、4799）未发现评论区，当前已证实的 bookapi 也没有评论操作；本轮不伪造接口或空评论，不显示无效评论按钮。以后原站增加评论需重新核对。 |
| SF（公开目录） | 在固定 `sfacg_public` ID / `https://book.sfacg.com` 下接入原站 Common.ashx 的简评、长评和按需回复；不是执行导入规则里的脚本。真实接口返回 CommentID=0 的“评论系统维护中”，作为状态显示，不能算普通读者评论或“暂无评论”。SF 恢复服务后的真实非空长评/回复仍需再验。 |

## 实现约束

- `SourceComment` / `SourceCommentPage` 为独立模型，不改 Rust ABI。HTML 评论转为不可执行文本，保留换行、实体和图片占位；不加载远程头像、评论图或外部脚本。
- `BookCommentsRepository` 用 book ID、账号／书源代数、页码、评论类型、回复串和刷新代数隔离。只缓存成功结果：24 页／2 MiB／2 分钟。手动刷新废弃旧页；旧完成不能回填新缓存。
- 与既有 SharedReadPool / ReadRequest 一起使用。一个订阅者退出不能取消其他订阅者；最后一个退出取消物理任务。评论总等待最多 25 秒。轻书架 GetComments 不复用旧的不可取消读池，取消时关闭本次 WebSocket，且不会在迟到的设备编号读出后连接或自动重试。
- Flutter 页面支持下拉刷新、显式和滚动分页、失败保留已读评论、正确重试刷新页、去重、防循环、展开回复／引用与剧透隐藏。列表最多 2000 条／4 MiB。本书来源固定，不随发现页当前来源误变。
- iOS 沿用 AppleGlassCard、原生返回及配色；Android 沿用 Material You。手机和平板整行卡片，320 dp／2 倍字号回归通过。iOS 选源原生菜单不变，Android 底部毛玻璃不变。

## 验证

- 针对性回归：78 项通过；含书源解析、缓存取消、失败重试、320/1024 dp 大字布局及轻书架真实 loopback WebSocket 关闭测试。
- 全量 Flutter：920 项通过，14 项可选联网跳过；其中新增 4 个联网测试由下述命令单独开启，均通过。文库8 DOM 夹具用实际生成脚本在 Chromium 执行。
- `flutter test --no-pub --dart-define=LITETALE_COMMENTS_LIVE=true test/source_comments_live_test.dart`：轻书架、百科、哔哩和 SF 的真实公开读取通过。SF 的通过指正确呈现维护状态，不等于恢复评论服务。
- 公开样本数据、测试日志和计时仅存 `build/qa/source-comments-2026-11-01/`，不打包入应用。QA 轻书架使用独立且在请求前持久化的安装标识，不读取用户账号或真实应用安全存储。报告没有 Cookie、Token 或安装标识正文。
- 本轮没有实体 iPhone/iPad/Android 连接；widget 与桌面网络验证不替代实体平台验收。打包记录另附。

## 接口依据

- [轻书架官方 Flutter GetComments](https://github.com/LightNovelShelf/Flutter/blob/6105cef68c7a09abcf8ec5e80cc5d107f2418462/lib/data/api/api_client_comments.dart) 与 [返回模型](https://github.com/LightNovelShelf/Flutter/blob/6105cef68c7a09abcf8ec5e80cc5d107f2418462/lib/data/api/models/comment.dart)。独立实现本项目模型和视图，没有复制上游界面。
- [百科样本原页](https://lnovel.tw/books-3638)。
- [哔哩公开书评页](https://www.bilinovel.net/reviews_88_1.html)。
- [SF 原站请求脚本](https://rs.sfacg.com/web/novel/js/v1/request-1.0.16.js) 与 [展示脚本](https://rs.sfacg.com/web/novel/js/v2/detail-1.0.32.js)。
- [幻梦公开书籍页](https://www.huanmengacg.com/index.php/book/info/8676)。
