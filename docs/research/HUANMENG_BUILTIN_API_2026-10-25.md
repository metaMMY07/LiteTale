# 幻梦轻小说内置 API 接入

日期：2026-10-25。范围：iOS 1.1.0 修订；Android 不启用本轮新源。

## 依据与真实网络观察

- 原站：https://www.huanmengacg.com/
- 作者发布的 8.1 API 版规则：https://www.yckceo.com/yuedu/shuyuan/content/id/7144.html
- 本机 REA 普通 Chromium 访问公开搜索接口、等待 4 秒后，仍停在 Cloudflare `Just a moment...`，没有取得有效 API JSON。Python 普通请求得到 HTTP 403。没有更换主机、伪造验证状态或执行下载规则中的脚本。
- REA 证据：`ev_5a4cb59d8a81cf7d9f5001038457e573548c39d8f49dfdf40397697531b28346`；本机原始记录位于 `build/qa/huanmeng-api-2026-10-25/rea-api-browser-evidence.json`。
- 以下字段与路径来自作者公开规则，属于接口契约证据；人工 JSON 测试及模拟器内的受控响应不表示真实原站已可读。

## 四个公开端点

固定 origin 为 `https://www.huanmengacg.com`，固定路径前缀为 `/index.php/bookapi/`。作者公开的静态参数为 `password=bookapi`。

| 操作 | 路径和参数 | 数据 |
| --- | --- | --- |
| 最新、分类、完结、搜索 | `search?password=bookapi&page=1&size=20`；搜索增加 `key`，分类增加 `tags`，完结增加 `state=2` | `data.list`，可选 `data.total` |
| 详情 | `detail?password=bookapi&id=书号` | `data.id/name/author/pic/intro/kind` |
| 目录 | `chapters?password=bookapi&id=书号&size=5000` | `data.list`；章节 `bid/id/name` |
| 正文 | `content?password=bookapi&bid=书号&cid=章节号` | `data.content` HTML |

没有发现可据以实现 API 排行的公开参数。因此新源使用“推荐、分类、完结、全部”；推荐为最新更新。50 个 `tags` 编号来自同一规则的公开分类列表，不推测额外端点。

## 实现

- `HuanmengSource` 为独立内置适配器；书籍 `hm:书号`、章节 `hm:书号:章节号`。详情、目录、正文均校验归属和结构，源错误不会成为空白成功。
- iOS 普通 WebKit 会话负责请求，Cookie 留在平台。请求串行，最短间隔 100 ms，同一修订、同一 URL 的并发请求合并；单次 API 操作最多 9 秒，包含排队。目录另有整次预算及总章数限制。
- 页面和 fetch 响应均限制 2 MiB。fetch 使用固定应用脚本、同源凭据、拒绝重定向与中止超时，不执行导入规则脚本。
- 同源 fetch 的 HTTP 429 读取实际 `Retry-After` 秒数或 HTTP 日期，不自动重试或切换主机。已核查本机固定版本 `webview_flutter_wkwebview 3.23.0`：首次主框架导航的错误回调没有 URL 或响应头，不能声称读取了它的 Retry-After。首次页面明确显示限流而头不可得时，使用有限的 60 秒冷却；不增加探测请求来猜测响应头。未为此改动文库8共用网页组件的接口。
- 原站验证通过可见正常网页完成。仅当前目标和完整查询对应的有效数据可确认；挑战页、硬拒绝、空详情、错误书号和旧修订均不可确认。确认结果仅进入有界短时 RAM，Cookie 不导出。
- 导航开始、排队、原生调用、迟到结果及验证返回都受修订与生命周期检查。挑战后的旧 renderer 停止，防止后台挑战脚本继续运行。
- 首页以实际第一页及 `maxPage` 初始化，续页从第二页开始；分类、完结和全部使用原站参数。封面使用原站公开 Referer。

## 旧导入源修复与保留

用户截图的 `#zhangjie` 是详情页内目录锚点，并非新网络主机。规则引擎只在目录上下文中允许它解析到已获取详情页的同源地址，网络请求去掉片段；同文档分页锚点表示结束。其他身份、跨源、私网、凭据与脚本地址校验没有放宽。

旧规则 ID、`src:` 书籍、书架及阅读记录保留。iOS 选择器将旧规则标为“（导入）”，用户可选择独立的内置“幻梦轻小说”。没有将旧记录静默改写成 `hm:`。

## 验收边界

- 单元测试：四端点映射、分页、归属校验、正文和图片处理；并发合并、429 冷却、排队超时、旧结果丢弃、大小边界、可见验证接纳；首页从第二页继续。
- iOS 模拟器：原生 WebKit 执行固定 fetch/probe 脚本，使用明确标记的离线 Response 夹具检查 JSON、429 响应头、流大小上限及正文中的错误字样不被误判为挑战。
- 原站联网验收尚未通过：当前测试网络触发原站验证。最终 IPA、模拟器结果与摘要另存到交付目录的 `validation.json`；不能将受控夹具写成真实原站搜索、目录或正文通过。
