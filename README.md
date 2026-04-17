# Raycast AI CLI Launcher

用 Raycast 快捷键从 Finder 当前目录启动 Claude Code 或 Codex CLI，并跟随 cc switch 当前选择的 provider。

这个仓库只放脱敏脚本：不会保存 API key，也不会写死本机用户名、Node 版本或私有路径。API key 由本机的 `~/.cc-switch/cc-switch.db` 在启动时读取。

## 功能

- 从 Finder 当前窗口目录启动；没有 Finder 窗口时回退到桌面，再回退到 `$HOME`
- 支持 Claude Code：会员账号登录时走原本的 `claude`；API provider 有 `ANTHROPIC_API_KEY` 时自动加 `--bare`，避免 Claude Code 同时检测到 claude.ai token 和 API key 的冲突提示
- 支持 Codex CLI：读取 cc switch 当前 Codex provider；对 360 这类 OpenAI-compatible API provider 自动导出 `OPENAI_API_KEY`，并补上 Codex CLI 所需的 `requires_openai_auth=false`
- 默认优先使用 Ghostty，也保留 iTerm 和 Terminal fallback
- Ghostty 支持两种启动模式：复用现有实例或直连二进制启动

## 使用

1. 把 `launch-claude-code.sh` 和/或 `launch-codex-cli.sh` 放进 Raycast Scripts 目录
2. 在 Raycast 设置里打开 **Extensions -> Scripts**
3. 给 `Launch Claude Code` 和 `Launch Codex CLI` 绑定快捷键

建议：

- `Launch Claude Code`: `Option + Command + C`
- `Launch Codex CLI`: `Option + Command + X`

## cc switch

脚本会读取：

```text
~/.cc-switch/cc-switch.db
```

Claude:

- 当前 provider 为会员账号/官方登录时，不注入 API key
- 当前 provider 通过 cc switch 保存了 `ANTHROPIC_API_KEY` 时，启动时注入该 key，并使用 `claude --bare`

Codex:

- 当前 provider 为 ChatGPT/Auth 登录时，不注入 API key
- 当前 provider 为 API key 模式时，启动时注入 cc switch 保存的 `OPENAI_API_KEY`
- 当前 provider 的 base URL 是 `https://api.360.cn/v1` 时，会追加：

```text
-c model_providers.custom.env_key="OPENAI_API_KEY"
-c model_providers.custom.requires_openai_auth=false
```

## Ghostty 模式

脚本顶部有：

```bash
GHOSTTY_LAUNCH_MODE="${GHOSTTY_LAUNCH_MODE:-reuse}"
```

可选值：

- `reuse`: 默认。复用现有 Ghostty app 实例，Dock 里更干净；macOS/Ghostty 可能会弹出 “Allow Ghostty to execute ...” 确认
- `direct`: 直接调用 Ghostty binary 的 `--command`，通常不会弹执行授权弹窗；macOS 上可能出现多个 Ghostty Dock 图标

如果你更在意免确认弹窗，可以改成：

```bash
GHOSTTY_LAUNCH_MODE="${GHOSTTY_LAUNCH_MODE:-direct}"
```

## 依赖

- Raycast
- Ghostty、iTerm 或 Terminal
- `sqlite3`，macOS 默认自带
- Claude Code CLI 或 Codex CLI
- 可选：cc switch

## License

MIT
