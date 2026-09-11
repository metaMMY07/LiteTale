# LiteTale 工作约定

- 主工程和唯一工作目录为 `D:\Projects\LiteTale`。C 盘旧工程内容已由用户手动清空，原目录可能仍作为空目录保留。
- 接手先读 `docs/LUNA_HANDOFF_0.0.18.md`，并检查 `git status`；本轮多书源实现保留在工作区。
- 用户要求一次只使用一个书源，设置里切换并分别保留账号登录；不得混合不同源的书架、搜索和历史。
- 用户明确禁止批量删除文件或目录。不得执行 `del /s`、`rd /s`、`rmdir /s`、`Remove-Item -Recurse`、`rm -rf`。确需删除时仅能一次删除一个明确路径的文件；需要批量删除则请用户手动处理。
- Android 构建入口为 `tools/build_android.ps1`。设备测试 fixture 不是用户真实账号的数据，不要据此声称受限接口已实测通过。
- 2026-09-11 迁移审查：C 盘 `C:\Users\30622\Documents\Codex\2026-08-31\x\work\wild-source` 中 Astra 的 60 个已修改或新增路径均已在本工程找到；D 盘包含后续正式版、品牌和 GitHub 发布修正。后续 Astra 工作只在 `D:\Projects\LiteTale` 进行，不要回到 C 盘旧目录编辑。
- Astra 后续只在 `D:\Projects\LiteTale` 工作；C 盘旧工程内容已不存在，不要尝试从 C 盘恢复或继续编辑。
