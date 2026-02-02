#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Launch Claude Code
# @raycast.mode silent
# @raycast.icon 🤖
# @raycast.packageName Claude Code

# Documentation:
# @raycast.description 在当前 Finder 目录下启动 Claude Code
# @raycast.author YourName

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

# 写入临时脚本，Ghostty 执行这个脚本
SCRIPT="/tmp/claude-launch-$$.sh"
cat > "$SCRIPT" << EOF
#!/bin/zsh -i
cd "$TARGET_PATH"
exec claude --dangerously-skip-permissions
EOF
chmod +x "$SCRIPT"

# Ghostty 执行临时脚本
open -n -a Ghostty.app --args -e "$SCRIPT"
