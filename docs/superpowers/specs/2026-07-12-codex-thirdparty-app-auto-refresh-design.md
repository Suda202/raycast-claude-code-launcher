# Codex ThirdParty 每周更新设计

## 目标

官方 `/Applications/ChatGPT.app` 更新后，每周自动检查一次独立的 `~/Applications/Codex ThirdParty.app`。发现新版时安全刷新 App 副本，同时保持第三方实例的身份和数据隔离。

不修改以下目录，因此更新不会影响聊天记录、认证或第三方模型配置：

- `~/.codex-thirdparty`
- `~/Library/Application Support/Codex-ThirdParty`

## 结构

更新逻辑集中在 `codex-thirdparty-update.sh`，Raycast 启动脚本不负责复制 1.4GB App。Codex 自动化每周调用一次：

```bash
./codex-thirdparty-update.sh --update
```

更新器提供两个入口：

- `--check`：只比较官方与 ThirdParty 的版本、Build、Bundle ID 和版本标记，不写入。
- `--update`：需要更新且 ThirdParty 未运行时，执行安全刷新。

## 安全刷新流程

1. 读取官方 App 的 `CFBundleShortVersionString` 和 `CFBundleVersion`。
2. 若 ThirdParty 版本、Bundle ID 和版本标记均一致，直接返回 `status=current`。
3. 若 ThirdParty 正在运行，返回 `status=deferred`，不退出应用、不替换文件。
4. 获取目录锁，避免人工执行与每周任务同时复制。
5. 在 `~/Applications` 同一文件系统创建临时目录，用 `ditto` 完整复制官方 App。
6. 将临时副本改为独立身份：
   - `CFBundleIdentifier = com.openai.codex.thirdparty`
   - `CFBundleName = Codex ThirdParty`
   - `CFBundleDisplayName = Codex ThirdParty`
   - 删除官方的 `Codex` 别名
7. 对临时副本执行 ad-hoc 深度签名并严格验证。
8. 再次读取官方版本；若复制期间官方 App 发生变化，本次失败并保留旧版。
9. 把旧副本移入临时回滚位置，再原子换入新副本。
10. 对正式路径再次验证签名、版本和 Bundle ID；失败则恢复旧副本。
11. 写入 `~/.codex-thirdparty/.thirdparty-app-source-build`，清理临时目录。

## 状态与失败处理

- `status=current`：已经是最新版。
- `status=updated`：更新完成，自动化复核版本和签名。
- `status=deferred`：App 正在运行或已有更新任务；本次不改动。
- `status=failed`：复制、签名、竞态或安装后验证失败；旧副本保持可用。

自动化不得为了更新而强退 App。若本周延后，下周继续检查，也可以在退出 ThirdParty 后手动执行更新器。

## 调度

- 周期：每周一次
- 时间：每周日 10:00
- 时区：Asia/Singapore（由本机 Codex 自动化使用本地时区执行）
- 执行环境：本机项目 `/Users/suda/Projects/raycast-scripts`

## 验证

fixture 回归测试覆盖：

1. 版本一致时不复制。
2. 旧版正确更新并重写独立身份。
3. App 运行中延后。
4. 签名失败保留旧版。
5. 官方 App 在复制期间变化时保留旧版。
6. 副本缺失时可重建。
7. 安装后验证失败时回滚。
8. 并发更新时跳过第二个任务。
9. 崩溃遗留的失效锁可自动恢复。
10. 首次安装后的验证失败不会留下破损 App。

此外使用官方真实 App 做临时端到端复制，验证 `ditto`、身份重写、ad-hoc 签名、严格签名校验和版本标记均能处理当前 1.4GB 应用包。
