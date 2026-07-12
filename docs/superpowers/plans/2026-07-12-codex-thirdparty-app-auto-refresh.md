# Codex ThirdParty 应用副本自动更新 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在启动第三方 Codex 前按官方 ChatGPT.app 的版本指纹自动刷新独立应用副本，并在更新失败时安全回退到旧副本。

**Architecture:** 新增一个可 source 的 Shell helper，负责版本指纹、临时复制、Bundle 身份重写、签名验证和原子替换；Raycast 启动脚本只负责调用 helper、处理运行中实例和启动流程。版本标记保存在 `~/.codex-thirdparty`，不进入应用包，聊天与认证数据完全不受影响。

**Tech Stack:** Bash 5-compatible shell features available on macOS, `ditto`, `plutil`, `codesign`, `sqlite3`/existing Raycast launcher.

---

### Task 1: 建立应用同步 helper 的失败测试

**Files:**
- Create: `tests/codex-thirdparty-app-sync.test.sh`
- Create: `codex-thirdparty-app-sync.sh`

- [ ] **Step 1: 写最小测试 fixture 和测试断言**

测试脚本创建临时的 `Source.app` 与 `Clone.app`，在 `Contents/Info.plist` 写入版本、Bundle ID 和可执行文件；用临时 `codesign` stub 返回成功。测试调用 helper 的 `sync_app_clone`，断言：版本指纹变化时 clone 的 Bundle ID 为 `com.openai.codex.thirdparty`，并生成与源版本一致的 marker。

测试核心断言形态：

```bash
assert_eq() {
  [ "$1" = "$2" ] || { printf 'expected=%s actual=%s\n' "$1" "$2" >&2; exit 1; }
}

sync_app_clone
assert_eq "$(plutil -extract CFBundleIdentifier raw "$CLONE_APP/Contents/Info.plist")" "com.openai.codex.thirdparty"
assert_eq "$(cat "$MARKER_FILE")" "26.707.51957|5175"
```

- [ ] **Step 2: 运行测试确认失败**

运行：

```bash
bash tests/codex-thirdparty-app-sync.test.sh
```

预期：失败，原因是 `codex-thirdparty-app-sync.sh` 尚未提供 `sync_app_clone`。

- [ ] **Step 3: 添加失败场景断言**

在同一测试中加入三个独立场景：

1. marker 与源版本一致时，clone 的 `mtime` 不变；
2. `codesign` stub 返回非零时，旧 clone 的 Info.plist 和 marker 不变；
3. helper 发现 `THIRDPARTY_INSTANCE_RUNNING=1` 时不执行复制。

- [ ] **Step 4: 再次运行测试确认仍按预期失败**

运行同一命令，确认失败来自缺少 helper 实现，而不是 fixture 或断言错误。

### Task 2: 实现安全的版本检测与原子刷新

**Files:**
- Modify: `codex-thirdparty-app-sync.sh`
- Test: `tests/codex-thirdparty-app-sync.test.sh`

- [ ] **Step 1: 定义可注入路径和版本函数**

实现以下接口，默认值指向真实应用，但测试可通过环境变量替换：

```bash
OFFICIAL_CODEX_APP="${OFFICIAL_CODEX_APP:-/Applications/ChatGPT.app}"
THIRDPARTY_CODEX_APP="${THIRDPARTY_CODEX_APP:-$HOME/Applications/Codex ThirdParty.app}"
THIRDPARTY_APP_MARKER="${THIRDPARTY_APP_MARKER:-$HOME/.codex-thirdparty/.thirdparty-app-source-build}"
DITTO_BIN="${DITTO_BIN:-/usr/bin/ditto}"
PLUTIL_BIN="${PLUTIL_BIN:-/usr/bin/plutil}"
CODESIGN_BIN="${CODESIGN_BIN:-/usr/bin/codesign}"

app_version_fingerprint() {
  local app="$1"
  printf '%s|%s' \
    "$($PLUTIL_BIN -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" \
    "$($PLUTIL_BIN -extract CFBundleVersion raw "$app/Contents/Info.plist")"
}
```

- [ ] **Step 2: 实现刷新条件**

`needs_app_refresh` 在以下任一条件成立时返回成功：副本不可执行、marker 不存在或不匹配、Bundle ID 不等于 `com.openai.codex.thirdparty`。当 `THIRDPARTY_INSTANCE_RUNNING=1` 时强制返回失败并记录跳过原因。

- [ ] **Step 3: 实现临时复制和身份重写**

`sync_app_clone` 使用 `mktemp -d` 创建同文件系统临时目录，然后执行：

```bash
"$DITTO_BIN" --rsrc --extattr "$OFFICIAL_CODEX_APP" "$staging_app"
"$PLUTIL_BIN" -replace CFBundleIdentifier -string com.openai.codex.thirdparty "$staging_app/Contents/Info.plist"
"$PLUTIL_BIN" -replace CFBundleName -string 'Codex ThirdParty' "$staging_app/Contents/Info.plist"
"$PLUTIL_BIN" -replace CFBundleDisplayName -string 'Codex ThirdParty' "$staging_app/Contents/Info.plist"
"$PLUTIL_BIN" -remove CFBundleAlternateNames "$staging_app/Contents/Info.plist" 2>/dev/null || true
"$CODESIGN_BIN" --force --deep --sign - "$staging_app"
"$CODESIGN_BIN" --verify --deep --strict "$staging_app"
```

- [ ] **Step 4: 实现源版本竞态保护**

复制和签名后重新读取官方版本指纹；若与复制前不同，删除 staging 并返回失败，保留旧副本和 marker。

- [ ] **Step 5: 实现原子替换与失败回滚**

在同一 `~/Applications` 目录中先把旧副本移动到 `.old-<pid>`，再把 staging app 移到正式路径；新路径验证成功后写入 marker 并删除旧副本。任一步骤失败时按相反顺序恢复旧副本。

- [ ] **Step 6: 运行测试确认通过**

运行：

```bash
bash tests/codex-thirdparty-app-sync.test.sh
```

预期：所有版本一致、版本变化、签名失败、源版本竞态和运行中跳过场景均 PASS。

### Task 3: 接入 ThirdParty Raycast 启动脚本

**Files:**
- Modify: `codex-thirdparty.sh`
- Modify: `codex-thirdparty-app-sync.sh`

- [ ] **Step 1: 移除启动脚本对副本必须预先存在的硬失败**

启动脚本只检查官方 `/Applications/ChatGPT.app` 和 wrapper；副本不存在时交给 helper 创建，不再直接输出 `ChatGPT App not found`。

- [ ] **Step 2: 在激活现有实例前后接入同步边界**

保留现有 `activate_existing_instance` 优先级：找到正在运行的 ThirdParty 实例就直接激活并跳过同步；找不到实例时先调用：

```bash
if ! sync_app_clone; then
  log_event "app clone refresh failed; attempting existing executable"
fi
```

若同步失败且副本可执行则继续启动旧副本；副本不可执行则退出并输出日志路径。

- [ ] **Step 3: 运行 dry-run 和 shell 检查**

运行：

```bash
bash -n codex-thirdparty.sh codex-thirdparty-app-sync.sh
CODEX_LAUNCH_DRY_RUN=1 ./codex-thirdparty.sh
```

预期：dry-run 输出 clone app 路径、`CODEX_HOME`、wrapper 路径和 launch cwd，不触发复制或启动。

### Task 4: 真实应用回归验证与文档

**Files:**
- Modify: `README.md`
- Test: `tests/codex-thirdparty-app-sync.test.sh`

- [ ] **Step 1: 记录真实官方版本与副本版本**

读取两个应用的 `CFBundleShortVersionString`、`CFBundleVersion`、Bundle ID，确认同步前后版本一致且副本仍为 `com.openai.codex.thirdparty`。

- [ ] **Step 2: 验证真实启动路径**

在 ThirdParty 未运行时执行启动脚本，观察 `/tmp/codex-thirdparty.log`，确认版本一致时记录跳过复制；手动修改 marker 后再次启动，确认触发刷新并保留 `~/.codex-thirdparty` 数据库。

- [ ] **Step 3: 验证两个应用身份并存**

确认官方 `/Applications/ChatGPT.app` 和 `~/Applications/Codex ThirdParty.app` 能同时启动，且两个主进程的 `--user-data-dir` 分别为 `Codex` 与 `Codex-ThirdParty`。

- [ ] **Step 4: 更新 README 使用说明**

记录：官方应用更新后，下一次冷启动 ThirdParty 自动同步；运行中不会替换；更新失败会保留旧副本；聊天记录和 API 配置位于应用包外。

- [ ] **Step 5: 运行最终检查并提交**

运行：

```bash
git diff --check
bash tests/codex-thirdparty-app-sync.test.sh
bash -n codex-default.sh codex-thirdparty.sh codex-thirdparty-app-sync.sh
```

确认没有暂存用户无关改动后提交：

```bash
git add codex-thirdparty.sh codex-thirdparty-app-sync.sh tests/codex-thirdparty-app-sync.test.sh README.md
git commit -m "feat: refresh Codex ThirdParty app copy"
```
