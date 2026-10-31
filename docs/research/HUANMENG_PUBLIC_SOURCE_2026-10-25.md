# 幻梦公开项目调研及重新接入

2026-10-25，Android 1.1.0 内部构建77。用户要求寻找与轻小说匹配、无需代理的幻梦书源，并直接接入测试。ESJ 从 `availableSources` 内置选择列表撤下，旧 `esj:` 标识、适配器和已保存数据保留。

## 公开项目

| 项目 | 实现 | 本次结论 |
| --- | --- | --- |
| [timyang2005/HuanmengPlugin](https://github.com/timyang2005/HuanmengPlugin/tree/d285de64fdc6092d012f245619d759468ca31278) | LightNovelReader 插件，公开9.0 API配置；搜索、详情、目录和正文分别请求原站四个端点 | 采用其公开接口约定，独立实现 Dart 接线；没有复制插件代码或构建其 APK |
| [Dancying/Legado-Adaptation-Plan](https://github.com/Dancying/Legado-Adaptation-Plan/blob/845a0595c051ea543bd433ceb276818bbaa8d0e5/res/BookSource_HUANMENGACG.json) | 阅读网页规则，JS恢复段落顺序 | 可作网页方案参考，但当前网页容器和指纹已经变化，不能原样导入就声称可读 |
| [nexhub-app/sources](https://github.com/nexhub-app/sources/blob/dedadf4e9706de570909613a8c9553b8972ca816/sources/novel/novel_huanmengacg.json) | 网页列表、元数据、原始目录和正文规则 | 公开网页选择器可参考；仅按初始CSS order排序不能证明当前正文顺序正确 |

插件的公开配置来自其 README 与 `HuanmengWebDataSource.kt`。这是供第三方阅读器使用的公开接入参数，区别于本机账号或会话信息。没有搜索非公开密钥、登录账号、访问受限内容或改变原站验证状态。

## 实测及问题

所有下列现场请求均在本机直连、无代理下进行，不把状态码200本身当作成功：

- 原站首页、书库、书名搜索均返回正常 HTML。书库链接为 `/index.php/book/info/<id>`。
- 《无职转生》目录仍有597条，但所测章节返回下架通知；这不算正文验收成功。
- 《败北女角太多了》公开网页目录有234章。正文使用 `#content`、32位指纹和隐藏段落；旧规则的24位实现与其不同，因此不直接搬旧JS。
- 现有原生适配器仍携带旧8.1接入配置。按开源插件公布的9.0配置请求，`/bookapi/content` 返回真实章节，而不是之前的密码错误公告。
- API的列表 `total=20, pages=1` 是当前页计数：第二页仍返回这些值，但实际有另一组20本书。原实现把它当全库总量，导致第一页结束或第二页报计数错误。

## 改动

- 更新 `HuanmengSource.publicApiKey` 至插件公开配置；`hm:<book>`、`hm:<book>:<chapter>` 标识和本机历史不变。密码错误公告仍被拒绝，不能存成正文或确认验证成功。
- 对带有匹配 `page/size/pages=1/total=当前行数` 的页级计数，采用满页继续、短页结束；其他全局 total 仍严格校验。返回页码与请求不匹配时明确失败。原有目录总量、去重、页数和总预算均保留。
- Android使用独立匿名HTTP传输，原站固定HTTPS、四个API路径，9秒预算包含排队；相同请求合并、不同请求串行，最小350ms间隔、最多16项排队，响应最多2MiB。
- 429遵守Retry-After，不自动换通道、重试或轮换域名；不共享文库8、轻书架或iOS网页登录Cookie。非JSON挑战和HTTP失败明确报错。
- Android开放幻梦内置入口；iOS继续原WebKit传输，公开配置同步更新，但本次没有构建或验收新的IPA。

## 验证

原生适配器联网测试 `test/huanmeng_source_live_test.dart` 使用显式 `HUANMENG_LIVE_TEST=true` 开关；没有往生产包加入测试代理。真实直接请求链通过：首页20本、第二页20本且有新书、搜索1条目标结果、详情和完整234章目录、首章411字符。整条测试约2825ms，属于本机网络和Dart执行时间，不是实体设备首帧承诺。

离线用例同时验证重复请求合并、串行、排队超时不迟到发请求、429停止后续请求、固定来源及JSON错误。联网原始摘要在 `build/qa/android-material-fix1-2026-10-25/huanmeng/`。最终APK与设备验收以本次发布记录为准；不保证原站未来不会变更接口或下架书籍。
