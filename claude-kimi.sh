#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Claude Kimi
# @raycast.mode silent

# Optional parameters:
# @raycast.icon 🌙
# @raycast.packageName Claude Code

# Documentation:
# @raycast.description 在当前 Finder 目录下启动 Claude Kimi
# @raycast.author suda

# 获取当前 Finder 窗口的路径
TARGET_PATH=$(osascript -e '
tell application "Finder"
  if exists front window then
    return POSIX path of (target of front window as text)
  else
    return POSIX path of (desktop as text)
  end if
end tell
')

# 使用目录名 + provider 前缀作为会话名
SESSION_NAME="kimi-$(basename "$TARGET_PATH")"

# 构造命令
SCRIPT="/tmp/claude-kimi-$$.sh"
cat > "$SCRIPT" << EOF
#!/bin/zsh -i
# 启动后立刻删除临时脚本，避免留下启动痕迹
rm -- "\$0"
cd "$TARGET_PATH"

# 检查会话是否已存在
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  tmux new-window -t "$SESSION_NAME" -c "$TARGET_PATH"
  tmux send-keys -t "$SESSION_NAME" "claude-kimi --permission-mode bypassPermissions" Enter
  tmux attach -t "$SESSION_NAME"
else
  tmux new -s "$SESSION_NAME" -c "$TARGET_PATH" "zsh -lic 'claude-kimi --permission-mode bypassPermissions'"
fi
EOF
chmod +x "$SCRIPT"

open -n -a Ghostty.app --args -e "$SCRIPT"
