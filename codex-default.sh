#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Codex Default
# @raycast.mode silent

# Optional parameters:
# @raycast.icon ◈
# @raycast.packageName Codex

# Documentation:
# @raycast.description 启动 ChatGPT 内的默认 Codex，跟随 CC Switch 当前状态
# @raycast.author suda

set -euo pipefail

CODEX_APP="/Applications/ChatGPT.app"
CODEX_BIN="$CODEX_APP/Contents/MacOS/ChatGPT"

if [ ! -x "$CODEX_BIN" ]; then
  echo "ChatGPT App not found: $CODEX_BIN"
  exit 1
fi

if [ "${CODEX_LAUNCH_DRY_RUN:-}" = "1" ]; then
  echo "CODEX_HOME=$HOME/.codex"
  echo "CODEX_ELECTRON_USER_DATA_PATH=default"
  echo "$CODEX_BIN"
  exit 0
fi

open -a "$CODEX_APP"
