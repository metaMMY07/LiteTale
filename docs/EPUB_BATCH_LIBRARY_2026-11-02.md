# 本地 EPUB 批量导入与分类管理

日期：2026-11-02。承接 [调研方案](D:/Projects/LiteTale/docs/research/EPUB_BATCH_LIBRARY_RESEARCH_2026-11-02.md)，完成第一阶段双端功能。应用版本配置仍为 1.1.1+81；本轮未打包、提交或推送。此前 Android build81 / iOS build23 安装包不包含本轮新增功能。

## 用户操作

1. 在「本地书籍」点击「导入 EPUB」，在系统文件选择器中一次选择多本文件。
2. 若已有分类，可选择将这批书加入某个分类，或不指定分类。导入后会显示目标分类。
3. 书库顶部显示当前处理文件、完成数量和结果。点击「详情」查看逐本结果，支持「停止后续导入」「继续未完成」「重试失败项」。
4. 点击文件夹按钮进入「管理分类」，可新建、重命名、上移、下移或移除分类。
5. 长按书籍或点击多选按钮，选择多本后「加入分类」。全选只作用于当前分类与搜索筛选后的可见书籍。
6. 在某个自定义分类中，可以将已选书籍「从当前分类移出」。这只解除该分类关系，书籍仍在「全部」和其他分类中。
7. 排序支持导入时间、书名、作者和最近打开；书名内数字按自然顺序比较，例如卷 2 在卷 10 前。

同一本书可加入多个分类，不会因此复制 EPUB。分类和排序保存到本机，旧书无需重新导入即可整理。搜索及页面状态在阅读返回时保留。

## 导入行为与阅读兼容

- 复用现有单本导入服务，一次只处理一个重解析任务；队列保存文件引用，不预先将整批 EPUB 读入内存。
- 同内容改名或重复导入按完整 SHA-256 跳过；同名但内容不同的文件独立保留。同系列不同卷不按书名合并。
- 损坏、超大或不支持的文件只影响该项，其余继续。成功一本便原子入库。
- 停止操作只取消尚未开始的文件，正在写入的单本安全收尾。失败重试和继续未完成不会重新导入已成功的项目。
- 队列由本地书库服务持有，离开导入页面后继续执行；再次进入可查看同一批结果。关闭结果面板会释放该批文件引用。
- 若 EPUB 已成功保存，但分类保存失败，结果显示「已入库，分类未保存」，提供仅重试分类的操作，不重新读盘解析 EPUB。
- 原有 128 MiB 单本限制、资源/路径/ZIP 校验、旧样式升级与原子发布流程保留；书籍 ID、CSS 排版和阅读位置不因分类改变。
- iOS 多本导入结束后留在书库，点击某一本才交给 Apple Books。单本导入保留原有打开方式；「最近打开」只记录用户打开动作，不模拟 Apple Books 内部阅读进度。
- 未增加批量物理删除、自动全盘扫描、文件夹持久扫描或云同步。在线书源、账号、Cookie、评论、全局字体与阅读翻页设置未改动。

## 实现位置

| 文件 | 责任 |
| --- | --- |
| [epub_import_queue.dart](D:/Projects/LiteTale/lib/services/epub/epub_import_queue.dart) | 整批状态、串行导入、停止/继续、失败和分类重试、路由外持有 |
| [local_epub_organization.dart](D:/Projects/LiteTale/lib/services/epub/local_epub_organization.dart) | 分类、成员关系、最近打开与排序的串行持久化 |
| [epub_library_query.dart](D:/Projects/LiteTale/lib/services/epub/epub_library_query.dart) | 分类/搜索筛选、稳定 ID 和自然排序 |
| [local_epub_library.dart](D:/Projects/LiteTale/lib/services/epub/local_epub_library.dart) | 初始化分类服务，持有队列，单本移除时清理相应管理记录 |
| [local_epub_library_page.dart](D:/Projects/LiteTale/lib/pages/local_epub_library_page.dart) | 多选文件、分类筛选、多选书籍、打开与单本移除 |
| [local_epub_library_controls.dart](D:/Projects/LiteTale/lib/pages/local_epub_library_controls.dart) | 分类管理、导入分类选择、结果面板与逐项详情 |

页面复用现有平台控件与 AppleGlassCard：iOS 继续使用原液态玻璃/原生菜单路径，Android 使用现有 Material You 主题，未调整底部导航。

## 存储与恢复

分类记录独立于原 EPUB 和书籍 manifest，位于应用私有根目录下的 `local_epub_organization`。未使用分类、排序或最近打开记录时不创建该目录，保留旧书库初始化行为。

- `organization-0.json`、`organization-1.json` 交替保存；每个有效快照保存完整分类状态，最多 4 MiB。
- 先写 `.pending` 文件并 flush，再 rename 为目标槽；启动时不接纳未提交的 pending 文件。
- schema1 快照包含代数和载荷的 SHA-256；读取选择校验通过的最大代数。
- 最新槽损坏但另一槽有效时恢复上次有效记录并提示用户核对。两个槽都无效则停止分类写入，保留原记录，书仍可在「全部」中打开。
- 较新 schema 不会被旧实现覆盖。分类目录和文件拒绝符号链接/非预期路径类型。
- 分类 ID 稳定、重命名不改 ID；成员只接受 `epub:<64位SHA-256>`，不会混入在线书源。
- 最多 256 个分类，名称 1–80 个字符，拒绝空名、同名和与预设「全部」「未分类」同名。

应用被系统终止后，已提交的 EPUB 和分类可恢复；尚未处理的系统临时文件并不保证重启后仍可访问，需要时应重新选择文件。本轮不承诺 iOS 被杀后继续后台导入。

## 验证结果

- 新增 21 项测试：导入/组织服务 11 项，界面流程 10 项。
- 相关 EPUB 测试 56 项通过；另对此前受目录初始化影响的旧 CSS/归档测试及新组织服务执行兼容回归，27 项通过。
- 全量 Flutter：**952 项通过，14 项跳过**。
- 8 个改动文件的目标静态分析无问题；最终记录见下方日志。
- 使用实际解析器批量导入 100 个自编 EPUB 夹具，再混入同内容改名文件和坏 ZIP；验证数量、去重、逐本失败、重启、原始字节和分类关系。
- 覆盖停止/继续、失败项重试、分类写入失败、校验/代数损坏、双槽均损坏、未知 schema、并发成员变更、自然排序及单本移除清理。
- 界面测试覆盖筛选后的全选范围、创建/重命名/移除分类、导入指定分类、离开并返回页面、iOS 单本/多本打开次数，以及 Android/iOS 风格的窄屏和大字号布局。

QA 资料：[验证目录](D:/Projects/LiteTale/build/qa/epub-batch-implementation-2026-11-02/)、[相关测试](D:/Projects/LiteTale/build/qa/epub-batch-implementation-2026-11-02/targeted-tests.log)、[兼容回归](D:/Projects/LiteTale/build/qa/epub-batch-implementation-2026-11-02/compatibility-tests.log)、[最终全量测试](D:/Projects/LiteTale/build/qa/epub-batch-implementation-2026-11-02/full-tests-final.log)、[最终静态分析](D:/Projects/LiteTale/build/qa/epub-batch-implementation-2026-11-02/analyze-final.log)。首次全量的目录清理失败记录保留在 `full-tests.log`，修正后最终全量全部通过，未修改旧测试来绕过问题。

## 尚未实测的范围

本轮没有连接实体 Android、iPhone 或 iPad。界面截图来自 Flutter widget 测试，iOS 控件走测试环境 fallback，不是 iOS 26 原生液态玻璃截图；Apple Books 打开次数以平台通道 mock 验证，未声称实体打开已验收。

系统选择器多选调用保留 EPUB UTI。iCloud 或其他文件提供器的下载/复制属于系统取件阶段，需要装机验证；当前 Android 插件在返回 Dart 前取件，若该阶段个别文件读取失败，仍可能使整次选择报错。这与入队后每本解析失败独立处理的范围不同。

100 本是小型自编 EPUB 正确性验证，不代表百本插图大书的实体耗时/内存测试，也不承诺瞬时完成。本轮未改版本号或重新封装，测试旧安装包看不到该功能。
