# Codex ThirdParty 应用副本自动更新设计

## 目标

官方 `/Applications/ChatGPT.app` 更新后，下一次启动 `Codex ThirdParty` 时自动刷新独立应用副本，避免副本版本过旧而无法启动，同时继续保持以下隔离：

- 默认 ChatGPT/Codex 使用 `~/.codex`，由 CC Switch 当前 Provider 决定走官方账号或 API。
- Codex ThirdParty 使用 `~/.codex-thirdparty` 和独立 Electron 用户数据目录。
- macOS 与 Raycast 将两个实例识别为不同应用。

## 方案

采用“启动时按需同步”，不增加后台守护进程。

启动脚本读取官方应用的 `CFBundleShortVersionString` 与 `CFBundleVersion`，组成源版本指纹。只有同时满足“第三方实例未运行”且以下任一条件时才刷新副本：

- 副本不存在或主程序不可执行；
- 已保存的源版本指纹与官方应用不一致；
- 副本的 Bundle ID 不是 `com.openai.codex.thirdparty`。

版本一致时直接启动，不复制 1.4GB 应用文件。

## 刷新流程

1. 将官方应用复制到 `~/Applications` 下的临时目录。
2. 把副本名称改为 `Codex ThirdParty`，Bundle ID 改为 `com.openai.codex.thirdparty`，并移除会干扰搜索的官方别名。
3. 对临时副本执行本机 ad-hoc 深度签名，并用 `codesign --verify --deep --strict` 验证。
4. 再次读取官方版本指纹；若复制期间官方应用发生变化，则放弃本次刷新，保留旧副本。
5. 先把旧副本重命名为回滚副本，再把新副本原子移动到正式路径。
6. 新副本就位后保存源版本指纹，再删除回滚副本。

聊天记录、认证、API 配置和数据库均位于应用包之外，因此刷新应用副本不会修改这些数据。

## 失败处理

- 复制、修改身份、签名或验证失败时，不替换旧副本。
- 若旧副本仍可执行，则记录错误并继续启动旧副本。
- 若没有可用旧副本，则启动脚本明确失败，并把原因写入 `/tmp/codex-thirdparty.log`。
- 第三方实例已经运行时只激活现有窗口，不在运行中替换应用文件；更新延迟到下一次冷启动。

## 验证

使用临时小型 `.app` fixture 做回归测试，不复制真实 1.4GB 应用：

1. 源版本与标记一致时不刷新。
2. 源版本变化时刷新，并写入新的独立 Bundle ID 与版本标记。
3. 模拟签名失败时保留旧副本。
4. 复制期间源版本变化时放弃刷新并保留旧副本。
5. 第三方实例正在运行时跳过刷新。
6. 运行 Shell 语法检查、签名验证和启动 dry-run。

## 边界

- 不自动更新官方应用；官方更新仍由官方更新器负责。
- 不引入 LaunchAgent 或常驻文件监听。
- 不修改 CC Switch 的 Provider 选择逻辑。
- 不把聊天记录或认证数据复制进应用包。
