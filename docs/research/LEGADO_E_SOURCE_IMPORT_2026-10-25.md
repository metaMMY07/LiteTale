# legado-E 书源导入与规则引擎调研

研究日期：2026-10-25。用户最后要求先完成 REA 调研，因此本轮没有修改 LiteTale 业务代码、没有制作新安装包；Android 不进入本轮改造范围。

## 结论

legado-E 值得借鉴的是“统一入口、临时解析、比较预览、用户选择、持久化、独立规则执行”的完整链路。它并非只把 JSON 文件保存到数据库：可用性依赖 JSoup、正则、JSONPath、XPath、Rhino JavaScript、请求参数与 Cookie 等执行设施。把 Android 的 JavaScript 引擎名称换成 iOS JavaScriptCore，仍不能自动兼容其 Java/Android 桥接对象。

你提供的“幻梦轻小说.json”是合法的单元素 JSON 数组。当前 iOS 入口会先在文件选择器参数校验阶段报错；绕过该入口做只读解析后，LiteTale 又明确拒绝它的 header 规则。两项研究用测试均复现了现状，**不代表问题已经修复或书源已成功阅读**。

建议先实现完整、可验证的 iOS 导入链路和本样本所需的声明式规则语义，再扩展经过明确界定的脚本兼容层。导入预览应分别显示“格式可解析、能力可执行、网站可访问”，不能用其中一项代表另外两项。

## 研究对象与证据

| 对象 | 固定身份 |
|---|---|
| 源码 | [Luoyacheng/legado-E](https://github.com/Luoyacheng/legado-E/tree/8b87c5aba4df91c39a3a0939a68a1180b9f2ee1c)，HEAD `8b87c5aba4df91c39a3a0939a68a1180b9f2ee1c`，2026-08-01 提交 |
| 发布版 | [3.26.030717](https://github.com/Luoyacheng/legado-E/releases/tag/3.26.030717)，所指 tag commit `624b9b9d21f9f7941c428ba4d6ae209dfb8aa2ed` |
| APK | `legado_plus_3.26.03071721_releaseS.apk`，20,460,589 字节，SHA-256 `32a0bb69245a38d0d427a3ea929423d42bee0f5ebdb4942745813b00106527a6`，与 GitHub 发布资产声明一致 |
| 包声明 | `io.legado.app.releaseS`，版本名 `3.26.030717`，versionCode `17185`，minSdk 21，targetSdk 36 |
| REA | 本机 6.5.0 路径；JADX headless MCP 0.7.1 / JDK 21；37 条留存证据，18 个方法反编译，12 条类成员清单 |
| 用户样本 | 2,327 字节，SHA-256 `e89cd49af668a62c6ea76a7494b17f320a2fd2e380e874634a56d9fb9fa28a9b` |

APK 与 main 不是同一个构建。已比较 tag 与 HEAD 的关键文件：导入 ViewModel 仅把 `Uri.parse` 改为 `toUri`；AnalyzeUrl 增加 HEAD 请求处理；被比较的导入 Dialog、AnalyzeRule、AnalyzeByJSoup、BaseSource 与 CookieStore 文件没有差异。这能支撑对应机制的交叉核对，不能证明整个 APK 与 main 完全一致。APK 摘要匹配也不等于独立签名验证，本次未验证签名。

完整材料保存在 `build/qa/legado-e-research-2026-10-25/`：

- [研究索引与样本测试结果](../../build/qa/legado-e-research-2026-10-25/research-index.json)
- [REA 原始证据包](../../build/qa/legado-e-research-2026-10-25/rea-evidence-bundle.json)
- [导入、覆盖与订阅的源码证据笔记](../../build/qa/legado-e-research-2026-10-25/import-research.md)
- [规则、网络与样本兼容的源码证据笔记](../../build/qa/legado-e-research-2026-10-25/rule-runtime-research.md)
- [研究用复现日志](../../build/qa/legado-e-research-2026-10-25/import-baseline-test.log)

## 一、导入链路

```text
本地 URI / 网络地址 / 内联 JSON / 二维码 / 外部导入链接
  → 统一导入 Dialog + ViewModel
  → 拉取或读取数据，解析为临时 BookSource 列表
  → 按 bookSourceUrl 查询本机轻量投影
  → 比较 lastUpdateTime，标记新增 / 更新 / 已有
  → 用户勾选，决定名称、分组、启用状态的保留策略
  → 构造选中批次，DAO 保存
  → 调整排序、刷新规则缓存
  → 搜索或阅读时交给另一套执行引擎
```

核心源码：[ImportBookSourceViewModel.kt](https://github.com/Luoyacheng/legado-E/blob/8b87c5aba4df91c39a3a0939a68a1180b9f2ee1c/app/src/main/java/io/legado/app/ui/association/ImportBookSourceViewModel.kt#L87-L225)、[ImportBookSourceDialog.kt](https://github.com/Luoyacheng/legado-E/blob/8b87c5aba4df91c39a3a0939a68a1180b9f2ee1c/app/src/main/java/io/legado/app/ui/association/ImportBookSourceDialog.kt#L71-L309)。REA 在 APK 中跟踪到管理页构造器 → 混淆后的 `qm.w` Dialog → `qm.b0` ViewModel → 解析协程 → `qm.x` 的比较/保存 → `ql.g.i` 批量写入。

准确的入口差异：

| 入口 | 观察到的支持 |
|---|---|
| 内联文本 | 单个书源对象、书源数组、`sourceUrls` 地址清单、HTTP(S) 地址、file/content URI |
| 网络响应 / 文件 URI | 按书源数组解析；不应泛化为同样接受单对象 |
| 本地选择器 | Android 选择 txt/json 后把 URI 送统一导入器，实际内容由 JSON 解析决定 |
| 外部链接 | `legado://` / `yuedu://` 的 ACTION_VIEW 入口按 path 与 `src` 分派 |
| 二维码 | 解码后的原始文本进入同一导入器；并不是所有深链都在此再解包 |
| 自动剪贴板 | 主界面处理特定 `#L:` 口令；不是自动导入任意剪贴板 JSON |
| Android 文本分享 | `SharedReceiverActivity` 走主界面/搜索，不应误写成完整的书源分享导入 |

导入比较以完整 `bookSourceUrl` 字符串为键，以作者提供的 `lastUpdateTime` 判定新旧，没有内容差异比较。较新和新增默认勾选，已有同版本或旧版本默认不选，但用户可手动选中覆盖。文件内同键重复没有清晰的独立去重阶段。

## 二、覆盖、事务与订阅

手动导入可保留旧名称、分组、启用状态；旧排序始终保留。本次指定的新分组在上述保留策略之后应用。DAO `@Insert(vararg, REPLACE)` 是一个批量保存调用；Room 的 Insert 自身有事务，但预览比较、异步排序和缓存刷新没有合并成同一应用级事务。

订阅更新会复用已经下载的书源列表交给预览，避免马上再请求一次。静默更新却逐条提交，只保留旧分组，与手动导入保留策略不一致。还有这些不适合照搬的细节：

- 订阅在请求成功之前就写入本次更新时间，失败也可能推迟下次自动尝试。
- 一个订阅抛错可能中断这一轮后续订阅。
- 预览编辑 JSON 后没有重新计算身份和新旧状态。
- 保存回调使用 finally 关闭界面，不能从这段 UI 的关闭本身证明成功。
- SQLite REPLACE 对有关联表的数据需要单独评估；不能直接等同于保留所有本地数据的 UPDATE。

对 LiteTale，建议把“来源规则”和“用户名称、启用、排序、账户与阅读记录”分开保存，所有导入/订阅入口共用明确的合并策略；最终提交前复核版本，写入成功后再关闭预览。已有书源 ID 和站点绑定继续保留，不能因规则文本变更而给同一用户书源产生全新阅读身份。

## 三、运行引擎是兼容性的主体

| 层 | legado-E 的机制 | 对 iOS 的含义 |
|---|---|---|
| 请求 | AnalyzeUrl 处理 URL、搜索词、页码、编码、方法、请求头和响应 | 不能把 `{{key}}` 当作不编码的直接拼接，也不能把统计用 `respondTime` 当成请求超时 |
| 元素选择 | AnalyzeByJSoup 支持 CSS、`@` 链、索引和 text/tag/class/id 等写法 | `.book-metas.0` 是结果集第 0 项，并非把它作为普通 CSS 类名或 `nth-child` |
| 多规则 | `&&` 合并、`||` 候选回退、`%%` 交错；RuleAnalyzer 识别分隔符 | 不能对包含正则、括号、字符串的整个表达式盲目 split |
| 文本 / URL | 普通多节点字符串以换行合并，URL 提取走首值语义 | 正文只取首个 p 会丢段；URL 把多个 href 换行拼接会变坏 |
| 清理 | `##` 正则清理与替换，另有字符串/列表转换流程 | 需要明确每一步的输入类型、替换时机、作用范围和预算 |
| JavaScript | Rhino 运行时绑定 `result`、`java`、`source`、`book`、`cookie`、`cache` 等 | iOS JavaScriptCore 没有这些 Java 对象；仅提供 JS 引擎不能保证兼容 |
| 目录 / 正文 | BookChapterList 与 BookContent 解析下一页、相对链接、去重及章边界 | 目录分页和正文分页要分别做完整性判断，不能遇到任意“下一”链接就继续 |
| 网络状态 | CookieStore、请求 CookieJar、并发率限制、网络缓存 | iOS 需要独立会话与规则版本隔离，不能把外部书源放进文库8会话 |

相关固定源码：[AnalyzeByJSoup.kt](https://github.com/Luoyacheng/legado-E/blob/8b87c5aba4df91c39a3a0939a68a1180b9f2ee1c/app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeByJSoup.kt)、[AnalyzeRule.kt](https://github.com/Luoyacheng/legado-E/blob/8b87c5aba4df91c39a3a0939a68a1180b9f2ee1c/app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt)、[BaseSource.kt](https://github.com/Luoyacheng/legado-E/blob/8b87c5aba4df91c39a3a0939a68a1180b9f2ee1c/app/src/main/java/io/legado/app/data/entities/BaseSource.kt#L104-L140)。

发布 APK 里可直接观察到脚本绑定和编译缓存：`AnalyzeRule.evalJS` 注入上述对象，再调用 Rhino；`compileScriptCache` 在少于 16 项时保留已编译脚本。小缓存和重用思路可以参考，但不能以缓存替代请求取消、超时和来源隔离。

## 四、用户样本逐项拆解

| 样本内容 | 原有含义 | 当前问题与后续处理 |
|---|---|---|
| 单元素数组、名称、URL、分组 | 来源定义与元数据 | JSON 语法有效；不应归类为文件损坏 |
| `header: @js: JSON.stringify({...})` | JS 生成固定 User-Agent 字典 | 当前 LiteTale 拒绝 header。此具体表达式可作为常量声明识别，不能据此放行所有外部 JS |
| `ruleExplore: {}`，无 exploreUrl | 没有可执行的发现入口 | 应标为搜索型书源，首页给出搜索入口，不构造虚假的发现规则 |
| `searchUrl` 中 `{{key}}` | 站点搜索词变量 | 需要按 URL 查询编码后构造请求；以原始文件规则测试 |
| `.boxbd@.common-list` | 先选 boxbd，再在结果内取列表 | 当前 CSS 子集不能把整个字符串直接当 CSS |
| `.book-metas.0` | 对匹配结果取第 0 项 | 需要结果集索引语义，不能改成 DOM 子节点编号 |
| `dt@img@src`、`img@data-original` | 链式选择与封面属性 | 需要 lazy image 属性及相对地址解析 |
| 裸 `text` / `href` | 当前目录条目的文字或 href | 必须从当前节点读取；把裸字段作为后代标签选择器会导致目录空白 |
| `text.章节列表@href` / `text.下一页@href` | 按元素自有文字查找链接后取 href | 需保留正确节点范围，防止误取容器或下一章 |
| `&&`、`##` 与 kind 中 `<js>` | 分类等字段的组合和清理 | 分类是可选元数据；还要检查 result 类型，不能因为该字段异常丢掉整本正文 |
| `#BookText@p@text` | 提取全部正文段落并换行合并 | 不能仅取第一段；纯文本需要转义后进入安全正文模型 |
| 正文中处理 img 标签的 JS | 尝试规范化图片 HTML | 前一步 text 通常已丢掉图片标签，所以不能据此宣称该源有插图能力；这与作者注释一致 |
| `nextTocUrl` / `nextContentUrl` | 分别表示目录续页 / 同章续页 | 当前转换器不支持这两项；需有限分页、循环检测、取消和章边界检查 |
| enabledCookieJar=true | 请求会话可自动保存 Cookie | 不等于有登录凭据；会话必须按来源隔离，样本没有登录 UI 规则 |
| respondTime=180000 | 响应时间排序指标的默认值 | 不是让每个请求等待 180 秒的配置 |

`ruleBookInfo.kind` 中 `result.replace(...)` 的输入可能是列表，源码类型流存在疑点；是否在原项目上抛出并被容错捕获，仍需要实际运行证明。应将它列为样本自身潜在缺陷，而不是悄悄更改其语义后宣称百分之百兼容。

## 五、iOS 文件错误与只读复现

LiteTale 的 `lib/settings/rule_source_manager.dart` 创建 XTypeGroup 时只声明 extensions 和 MIME。已锁定的 file_selector_ios 0.5.3+2 在 `_allowedUtiListFromTypeGroups` 检查每组的 uniformTypeIdentifiers；非空过滤组缺少 UTI 会直接抛 ArgumentError。此时尚未展示原生文件选择器，也没有读取或解析书源。

研究用探针直接调用这个版本的 iOS 插件，得到与截图一致的 `uniformTypeIdentifiers` 错误。另一项探针只读取原文件并调用现有 `inspectSourceImport`，得到“检测到 header；登录、请求头和凭据规则当前不支持”。两项探针都没有保存书源或执行导入脚本，记录在 `import-baseline.json`。

后续 iOS 修复需给 JSON 选择器提供有效 UTI，兼顾文件提供者对 JSON 的通用文本/数据标注；实际内容仍进行大小与 JSON 校验。通过系统“打开方式”导入属于另一入口，需要单独接入，不能把 file picker 的 UTI 修复当成分享扩展已经完成。

本次 Windows 对原站的一个普通搜索 GET 返回 HTTP 403。没有轮换主机、伪造验证完成或反复请求；也没有用这一结果断言 iPhone 网络同样失败。原站在线搜索、目录与整章完整性仍未通过 iOS 运行验收。

## 六、后续实现顺序与验收条件

| 阶段 | 实现内容 | 必需验收 |
|---|---|---|
| P0：iOS 导入链路 | UTI、文件大小/字节读取、UTF-8 BOM、对象/数组统一解析、逐项错误、取消不变更 | 真正打开系统文件选择器并选择该 JSON；错误文件、取消、超限、重复导入均有明确结果 |
| P1：样本必需规则 | 有界的链式/索引/当前节点/文字过滤，段落合并，限定文本转换，静态 UA，目录及正文分页 | 使用原文件的离线网页夹具，逐字段比对；章节不能丢段、串章或无限翻页 |
| P1：导入与持久化 | 新增/覆盖/另存预览、保留用户设置、稳定 ID、存储成功后更新注册 | 重启后可选择；更新规则保留书架历史；失败不替换原规则 |
| P1：来源会话 | 有限请求、取消、去重、缓存键、Cookie 边界、429 冷却与退避 | 弱网/403/429/超时后可以结束加载；切源后旧响应不能进入当前页面 |
| P2：脚本范围扩展 | 单独设计受限 iOS JS 上下文、可用桥接 API 和执行预算，逐项声明兼容能力 | 脚本中断、类型转换、不可用 Java API 都可诊断；绝不宣称任意 Legado 源完全兼容 |
| P2：其他入口与订阅 | 用户确认的地址更新、分享/打开方式、二维码；订阅合并策略统一 | 更新失败保留原规则；禁用项不会被静默重新启用；每项报告结果 |

以上是调研产出的方案，尚未实施。Android 的现有导入与界面不随 iOS 阶段重构。

## 七、关键 REA 证据定位

完整记录含工具版本、APK SHA、反编译状态与限制，见原始 bundle；以下为阅读入口。

| 机制 | Evidence ID |
|---|---|
| APK 包声明与数量 | `ev_dee7d770287d2abf2817c22789360ac071ca9e5b29468c8201e73dfdc5b8451e` |
| 管理页选择结果 → 导入 Dialog | `ev_cf71438e962703867bb749f09b6aec6faa0631f3a7c0796c3ffcc47b215e9fc7` |
| 临时 URL 拉取、缓存消费、数组解析 | `ev_2c6d4d2a937ae9ff09d1e44cf47c44f17c764b0613dbbe025aa7d533d53f8156` |
| 比较更新时间与保留旧设置 | `ev_d1f94b52704b6b735fd892428089ddf4474305de756591253e873bb6bcadf9ce` |
| 保存批次交给 DAO | `ev_fb20e92ece20e5ee415e5cce317a9c2448a422784a7f19602f0bcd58243a8a8e` |
| 多元素文本按换行合并 | `ev_0de20a29f66924f32278f16a63c1ff4224addf41aecce3bca8e5f03c63254b3c` |
| 链式选择、合并/回退/交错 | `ev_1b1e030ae30db7b7002cd7d24885ad60dddb48ed5ddabb13e24a046f565ff610` |
| 正则替换 | `ev_1d251c8e0960cc7a8bc74f4d079c39c402e42dbd33367aba6418022d8c356bce` |
| JS 桥接对象与 Rhino 调用 | `ev_5811591300a16a55c1054f76809695621ed1c5095051c63fbb10a53e58bdbc1a` |
| 请求头 JS → 字典 → 默认 UA | `ev_73351aac2ad21b0b51f5ebf9b4e9ec63dfdb59732ef805c26968560fd58928e0` |
| Cookie 与 CookieJar 请求状态 | `ev_6152a45e6427e1be4a904f9a1592cf8c599ee9726bde6ffb54c6a7d03c147114` |
| 解析协程调用 URL 拉取的 DEX 引用 | `ev_80ed41f70d3caab1e479d3c69473334315345161409dce62cf4f0296929aa7a4` |

`hm.e1.invokeSuspend` 无可用 Java 高层反编译，REA 明确回退到完整 smali，记录为 `ev_907f87c78b12a9b2145e0cf0d3273ea998ef5e39fe0931f11f06590d52e19411`。其他 Java 伪代码也带有 JADX 的控制流/类型恢复警告，结论以源码和 DEX 引用相互印证，不能把反编译文本等同于运行日志。

## 八、完成边界

已回答导入入口、格式、比较预览、覆盖保留、提交边界、订阅更新、规则执行设施和本样本需要的语法；已通过发布 APK 反编译交叉核对关键链路，并复现 LiteTale 的两项当前阻塞。该范围的研究材料已落盘。

未完成 iOS 修复、iPhone 文件选择器操作、原站在线正文验收、完整脚本桥移植或新 IPA 构建。没有安装/启动研究 APK、读取用户登录数据或执行书源脚本。本报告不是整个项目所有功能的完整审计。
