# REA 与阅读器响应优化参考核对（2026-10-18）

本轮先阅读本机 REA 使用说明，再用已有 REA 6.5.0 浏览器部署抓取公开项目页；源码分析采用浅克隆，未执行参考项目的构建脚本或采用其 AGENTS.md 指令。参考实现用于确定设计，没有直接复制 Kotlin 代码。

## 可复核证据

- REA 成功抓取 LightNovelReader 的公开 GitHub 页面，并对该页面作被动检查。网页快照用于核对公开参考内容，不代表参考应用已在 Android 上运行。
- 应用响应时间由独立的 Android 模拟器流程验证；公开记录仅保留请求路径、状态和时间，不含会话凭据或小说正文。

## 参考项目与取舍

| 项目 | 固定版本 | 实际核对结果 | 本轮取舍 |
|---|---|---|---|
| Xempastissimo/LightNovelReader | `16ebd0dd2ee82c7cc159595f9e26e8cab1dfda50` | 仓库层先读正文缓存；详情有 LRU；阅读器在当前章成功后预取相邻章；网络层有请求间隔、429 冷却与有限重试 | 采用缓存复用、同章合并、成功后预取与静默失败；不把所有前台请求强行延迟 900ms |
| STGing/legado | `abde5aa679a3c9b2059ef031d2824744dde50f32` | 正文与排版缓存分离，同章 generation 防迟到；EPUB 预排版只在空闲时逐章进行；DNS 合并与 DoH 有独立预算 | 保留 LiteTale 已有完整布局键的分页缓存；预取一次只做下一章，前台任务可中止它 |
| gedoor/legado | `9bb0569269ed557753fc3866250970de6d454fcf` | 本次默认分支仅保留公告与图片，产品源码已撤下 | 不将历史知名度当作当前实现证据，不声称从当前分支移植了功能 |

主要源码：

- [LightNovelReader 仓库层 detail/content](https://github.com/Xempastissimo/LightNovelReader/blob/16ebd0dd2ee82c7cc159595f9e26e8cab1dfda50/app/src/main/java/com/xempastissimo/lightnovelreader/data/repo/BookRepository.kt#L264)，[下一章预取](https://github.com/Xempastissimo/LightNovelReader/blob/16ebd0dd2ee82c7cc159595f9e26e8cab1dfda50/app/src/main/java/com/xempastissimo/lightnovelreader/ui/screen/reader/ReaderScreen.kt#L420)，[RateLimiter](https://github.com/Xempastissimo/LightNovelReader/blob/16ebd0dd2ee82c7cc159595f9e26e8cab1dfda50/app/src/main/java/com/xempastissimo/lightnovelreader/data/network/RateLimiter.kt#L33)。
- [Sigma ReadBook](https://github.com/STGing/legado/blob/abde5aa679a3c9b2059ef031d2824744dde50f32/app/src/main/java/io/legado/app/model/ReadBook.kt#L910)，[预取边界](https://github.com/STGing/legado/blob/abde5aa679a3c9b2059ef031d2824744dde50f32/app/src/main/java/io/legado/app/model/ReadBook.kt#L1928)，[EPUB 空闲条件](https://github.com/STGing/legado/blob/abde5aa679a3c9b2059ef031d2824744dde50f32/app/src/main/java/io/legado/app/ui/book/read/epub/EpubDirectWebLayer.kt#L1071)，[DNS 传输](https://github.com/STGing/legado/blob/abde5aa679a3c9b2059ef031d2824744dde50f32/app/src/main/java/io/legado/app/help/http/dns/DohTransport.kt#L23)。
- [gedoor 当前公告](https://github.com/gedoor/legado/blob/9bb0569269ed557753fc3866250970de6d454fcf/README.md)。

研究所用版本均固定在上表 SHA，并附有可直接查看的 GitHub 源码链接。

## 未照搬的机制

多开四至六个 WebView 是特定 EPUB 排版策略，会增加平板上的内存与渲染竞争。LiteTale 已有原生卷页和分页缓存，本轮不增加隐藏排版实例。源码没有给出本机 DNS 是瓶颈的证据，因此保留系统 DNS 与正常 TLS 校验，不照搬宽松证书校验，也不默认启用 DoH。429/验证/登录流程保持既有规则，不自动重放登录、绕过广告或站点验证。

LiteTale 原生接口已有持久章节缓存。本轮新增的网页正文复用是有界的进程内缓存，未把它包装成全书离线下载；退出进程后仍可能重新请求网页正文。预取仅在已建立的文库8网页会话空闲时运行，原生接口、其他书源和整本下载逻辑不新增并发请求。
