#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Claude Minimax
# @raycast.mode silent

# Optional parameters:
# @raycast.icon 🚀
# @raycast.packageName Claude Code

# Documentation:
# @raycast.description 在当前 Finder 目录下启动 Claude Minimax
# @raycast.author suda

# 获取当前 Finder 窗口的路径
TARGET_PATH=$(osascript -e '
tell application "Finder"
  if exists front window then
    return POSIX path of (target of front window as text)
  else
    return POSIX path of (desktop as text)
  end if
end tell')

# Minimax 环境变量
export ANTHROPIC_BASE_URL=https://api.minimaxi.com/anthropic
export ANTHROPIC_AUTH_TOKEN=$MINIMAX_TOKEN
export ANTHROPIC_MODEL=MiniMax-M2.1

# 构造命令
SCRIPT="/tmp/claude-minimax-$$.sh"
cat > "$SCRIPT" << EOF
#!/bin/zsh -i
cd "$TARGET_PATH"
exec /Users/suda/.local/bin/claude --dangerously-skip-permissions
EOF
chmod +x "$SCRIPT"

open -n -a Ghostty.app --args -e "$SCRIPT"
