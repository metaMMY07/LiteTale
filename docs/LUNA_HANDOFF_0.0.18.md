# LiteTale 0.0.18-dev.1 → Luna 交接

主工程：`D:\Projects\LiteTale`。本次从 C 盘复制迁移，未删除旧目录。
分支：`feat/litetale-multi-source`，基线 `0fc73c4`。本轮修改保留在工作区，请先查看 `git status` 和 `git diff`，不要覆盖。
原工程备份：`C:\Users\30622\Documents\Codex\2026-08-31\x\work\wild-source`。迁移完成后的新增修改以 D 盘为准。
过程日志：`C:\Users\30622\Documents\Codex\2026-09-05\novels-astra-handoff\work`。

## 用户约定

- Android 名称 LiteTale，保留 Material You 原生页面、壁纸取色和六种主题色。
- 新用户无需账号即可进入首页；设置中选择书源，再登录该站账号。
- 一次只显示一个书源，切换不会退出另一站账号；记住最后选择。
- 文库8和轻书架搜索、收藏及阅读历史不能混合。
- 禁止批量删除文件或目录；C 盘备份由用户决定如何处理。

## 已实现的边界

- `lib/sources/book_source.dart` 定义书源协议和标识；轻书架书籍使用 `lns:<id>`，章节使用 `lns:<bookId>:<chapterId>`。
- `source_api.dart` 复用现有模型和页面入口，按书籍 ID 路由正文/详情；发现和搜索按当前书源路由。历史先按书源过滤再分页。
- `light_novel_shelf_source.dart` 适配 SignalR 书目、分类、排行、搜索、目录和正文。JSON 实测分页字段为 `data/totalPages`、详情为 `book.id/title/chapters`，列表字典仍保留 `Id/Title`；章节外层 `chapter` 小写，内层 `Content/Font` 大写。入口统一字段大小写，并兼容 `Chapter/Chapters`；不要只用自造 PascalCase 数据测试。
- `GetNovelContent` 的 `SortNum` 是目录顺序加一，不是章节 ID。正文 HTML 保持文字与图片顺序后进入原生阅读器。
- 专用 WOFF2 字体经 `rust/src/api/font.rs` 解码，FRB 工作线程转换为 TTF；Flutter 排版及显示使用同一字体。实际 `/font/*.woff2` 相对路径必须基于 `https://api.lightnovel.life/`，不是网页域名。真实章节字体约 1 MB，已通过直接下载核验。
- `shelf_session.dart` 用安全存储保留轻书架 RefreshToken，访问令牌内存缓存 30 秒；文库8维持原有 Cookie。切换书源不清除任何登录，退出仅作用于当前源。
- `ShelfLoginPage` 使用 Material You 原生邮箱/密码表单，按官方协议对密码做 SHA-256 后请求 `/api/user/login`，只保存返回的 RefreshToken。原网页方案在模拟器 WebView 上空白，已替换；密码不写入源码或持久化存储。
- 轻书架收藏目前是本地收藏，不是云书架同步；界面已提示。其授权离线下载、评论未接入，相关入口禁用或提示站点查看。
- 原插图死循环、搜索提交和主题配色修复已保留。不存在多个书源结果混排。

## 复现构建

```powershell
Set-Location D:\Projects\LiteTale
powershell -ExecutionPolicy Bypass -File tools/build_android.ps1
```

默认工具链：Flutter 3.29.3 / Dart 3.7.2、JDK 17、Rust FRB 2.11.1、Android NDK 27.0.12077973。
工具和缓存主要在 `D:\CodexToolchains`；Android SDK 在 `%LOCALAPPDATA%\Android\sdk`。
脚本默认使用本机代理 `127.0.0.1:10808`，可传 `-Proxy ''` 禁用或另指定。
Windows 未启用开发者模式时，首次 `pub get` 可能在依赖解析成功后报桌面插件 symlink 权限。脚本对此重试一次，并要求插件初始化成功；不可直接忽略失败后 `--no-pub` 构建，否则包中可能缺少 GeneratedPluginRegistrant，启动报 MissingPluginException。本次迁移时已复现并解决。
保持包名 `io.github.metammy07.novels`，版本号为 0.0.18-dev.1，split versionCode ARM64=2018、x86_64=4018。
当前使用原本地 debug 签名生成 release 模式 APK，适合测试及覆盖此前同签名版本；未发布到商店或 GitHub。

桥接再生成：`D:\CodexToolchains\frb-2.11.1\flutter_rust_bridge_codegen.exe generate --no-auto-upgrade-dependency --no-deps-check --no-dart-fix --no-build-runner`，需同一 Dart/Rust 环境变量。FRB 工具已核验官方 SHA-256。`cc` 依赖因 woofwoof 构建需要更新，版本固定在 Cargo.lock。

WOFF2 原生模块依赖 `libc++_shared.so`。`android/app/build.gradle.kts` 在 preBuild 时从所选 NDK 复制每个 ABI 对应的运行库到生成目录，不能省略，否则编译可通过但运行时报 dlopen 失败。APK 校验要求包含该库并检查 16 KB 对齐。

## 验证记录

- D 盘 Flutter 全套：54 项通过，包含两个真实匿名接口测试，无跳过。日志 `d-drive-tests.log`。
- 新书源/登录/设置/集成测试静态检查：No issues found，日志 `d-drive-analyze.log`。旧代码仍有原有分析提示，不代表整仓零提示。
- 第一轮 Android 15 集成测试验证游客入口、书源设置、输入搜索、共享详情与插图翻页、历史隔离和保存选择；数据为明确的本地 fixture。
- D 盘最终 Android 15 x86_64 设备集成测试通过：包含 WOFF2→TTF→FontLoader、无效字体异常返回、游客首页、设置切换、输入搜索、详情/插图翻页、历史隔离和选择持久化。日志 `d-drive-device.log` 以 `All tests passed.` 结束。
- 两次中间包分别暴露插件注册和 C++ 动态库打包问题，已修复；不要使用旧的中间 profile/release 包。最终交付以 `artifacts/0.0.18-dev.1` 中的 APK 和 SHA-256 为准。
- 最终 release APK：ARM64 与 x86_64 的 ZIP、签名、版本代码及所有原生库 16 KB 对齐校验通过。x86_64 包覆盖安装并冷启动成功；游客入口、设置切换到轻书架、真实匿名书目显示、强制停止后恢复所选源均通过手动设备核验。
- 新增原生登录和实际 JSON 字段回归后，纯本地测试 55 通过、2 个可选网络测试跳过；此前打开网络开关的全套为 54 通过。两类日志都随交接保留。

## Luna 接手重点

1. 用户已授权使用自己的轻书架账号进行验证；账号测试结果见最终验证补充。文库8真实账号尚未提供，不能把游客和 fixture 测试描述为两个账号均通过。
2. 轻书架真实账号测试已通过下述流程；其他账号权限和文库8真实登录需另行测试。服务器拒绝时应显示错误，不产生假书目。
3. 扩展新书源需在 SourceId/BookSource/注册表中独立接入，并按源划分本地数据；不要恢复旧版的混合推荐流。
4. 后续若要云书架、付费授权下载或新增第三书源，需要单独安排实现和测试。

## 最终真实账号验证补充（2026-09-11）

- 使用用户授权账号在 Android 15 x86_64 模拟器的原生登录表单成功登录；凭据未写入源码或交接文件。
- 最终 release APK 覆盖安装后，键盘输入 `86` 并提交，返回真实书目。打开 `8号出口`（书源 ID 16429），详情、目录正常。
- `0 地铁` 正文通过 API 字体路径加载并正确显示中文，共 27 页；翻页及菜单切换正常。
- `地图` 章节真实插图显示正常，点击插图、显示/隐藏菜单并翻页成功，未出现本次流程中的卡死或 ANR。
- 轻书架已登录 → 文库8游客 → 轻书架，保存的登录状态保留。随后强制停止并重启，再次输入搜索成功，验证了安全存储中的令牌可恢复实际访问。
- 中间测试的旧会话曾被服务器判定失效，具体失效原因未确认；重新登录后的上述切换、冷启动及再次搜索均通过。测试期间还使用过独立接口探针，不能据此保证会话永不被服务端撤销。
- ARM64 包仅完成构建、签名和 16 KB 对齐检查；设备运行测试使用 x86_64 模拟器，尚未在 ARM64 真机验证。
- 最终 APK、源码快照、SHA256SUMS、差异补丁、测试日志和此交接文件位于 `artifacts/0.0.18-dev.1`。分支修改尚未提交，源码 ZIP 包括新增文件；补丁只包括 Git 已跟踪文件的差异。

参考：Wild https://github.com/niuhuan/wild ，Novella https://github.com/celia-sh/Novella （archive/flutter），LightNovelShelf/Web https://github.com/LightNovelShelf/Web 。
