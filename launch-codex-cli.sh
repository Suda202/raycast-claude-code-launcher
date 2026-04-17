#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Launch Codex CLI
# @raycast.mode silent

# Optional parameters:
# @raycast.icon 🧠
# @raycast.packageName AI CLI Launchers

# Documentation:
# @raycast.description Launch Codex CLI from the current Finder folder and follow cc switch
# @raycast.author Suda202

# Ghostty launch modes:
# - reuse: use the existing Ghostty app instance and keep one Dock icon; macOS/Ghostty may ask before executing the temp script.
# - direct: call the Ghostty binary with --command; usually avoids the prompt, but macOS may show extra Dock instances.
GHOSTTY_LAUNCH_MODE="${GHOSTTY_LAUNCH_MODE:-reuse}"

TARGET_DIR=$(osascript -e '
  tell application "Finder"
    if (count of windows) > 0 then
      get POSIX path of (target of front window as alias)
    else
      get POSIX path of (desktop as alias)
    end if
  end tell' 2>/dev/null)

TARGET_DIR="${TARGET_DIR:-$HOME}"
TMP_SCRIPT="${TMPDIR:-/tmp}/codex-launch-$$.sh"
TARGET_DIR_QUOTED=$(printf '%q' "$TARGET_DIR")

cat > "$TMP_SCRIPT" << EOF
#!/bin/zsh
TARGET_DIR=$TARGET_DIR_QUOTED
EOF

cat >> "$TMP_SCRIPT" << 'EOF'
SENTINEL="$0.started"
if [ -e "$SENTINEL" ]; then
  exec /bin/zsh -l
fi
: > "$SENTINEL"

cd "$TARGET_DIR" || exit 1
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

for node_bin in "$HOME"/.nvm/versions/node/*/bin(N); do
  export PATH="$node_bin:$PATH"
done

unset OPENAI_API_KEY
unset OPENAI_BASE_URL
unset CODEX_API_KEY

CC_SWITCH_DB="$HOME/.cc-switch/cc-switch.db"
CODEX_ARGS=()

if command -v sqlite3 >/dev/null 2>&1 && [ -r "$CC_SWITCH_DB" ]; then
  CURRENT_PROVIDER="$(sqlite3 "$CC_SWITCH_DB" "select name from providers where app_type='codex' and is_current=1 limit 1;" 2>/dev/null)"
  CURRENT_AUTH_MODE="$(sqlite3 "$CC_SWITCH_DB" "select json_extract(settings_config,'$.auth.auth_mode') from providers where app_type='codex' and is_current=1 limit 1;" 2>/dev/null)"
  CURRENT_CONFIG="$(sqlite3 "$CC_SWITCH_DB" "select json_extract(settings_config,'$.config') from providers where app_type='codex' and is_current=1 limit 1;" 2>/dev/null)"

  if [ -n "$CURRENT_PROVIDER" ]; then
    echo "[cc switch] Codex provider: $CURRENT_PROVIDER"
  fi

  USE_OPENAI_API_KEY=0
  if [ "$CURRENT_AUTH_MODE" = "apikey" ] || printf '%s\n' "$CURRENT_CONFIG" | grep -q 'env_key = "OPENAI_API_KEY"'; then
    USE_OPENAI_API_KEY=1
  fi

  if printf '%s\n' "$CURRENT_CONFIG" | grep -q 'base_url = "https://api.360.cn/v1"'; then
    USE_OPENAI_API_KEY=1
    CODEX_ARGS+=(-c 'model_providers.custom.env_key="OPENAI_API_KEY"')
    CODEX_ARGS+=(-c 'model_providers.custom.requires_openai_auth=false')
  fi

  if [ "$USE_OPENAI_API_KEY" = "1" ]; then
    KEY_FROM_CC_SWITCH="$(sqlite3 "$CC_SWITCH_DB" "select json_extract(settings_config,'$.auth.OPENAI_API_KEY') from providers where app_type='codex' and is_current=1 limit 1;" 2>/dev/null)"
    if [ -n "$KEY_FROM_CC_SWITCH" ]; then
      export OPENAI_API_KEY="$KEY_FROM_CC_SWITCH"
    else
      echo "[cc switch] Current Codex provider needs OPENAI_API_KEY, but cc switch has no saved key"
    fi
  fi
fi

CODEX_BIN="$(command -v codex 2>/dev/null)"
if [ -z "$CODEX_BIN" ] && [ -x "$HOME/.local/bin/codex" ]; then
  CODEX_BIN="$HOME/.local/bin/codex"
fi

if [ -z "$CODEX_BIN" ]; then
  echo "[launch failed] codex command not found"
  read -k1
  exec /bin/zsh -l
fi

"$CODEX_BIN" "${CODEX_ARGS[@]}" || { echo "[launch failed] press any key to exit"; read -k1; }
exec /bin/zsh -l
EOF

chmod +x "$TMP_SCRIPT"

launch_with_terminal() {
  local script="$1"

  if [ -d "/Applications/Ghostty.app" ]; then
    if [ "$GHOSTTY_LAUNCH_MODE" = "direct" ]; then
      if command -v ghostty >/dev/null 2>&1; then
        ghostty --quit-after-last-window-closed=true --command="$script" && return 0
      fi
      if [ -x "/Applications/Ghostty.app/Contents/MacOS/ghostty" ]; then
        /Applications/Ghostty.app/Contents/MacOS/ghostty --quit-after-last-window-closed=true --command="$script" && return 0
      fi
    fi

    open -a Ghostty "$script"
    return 0
  fi

  if [ -d "/Applications/iTerm.app" ]; then
    osascript -e "tell application \"iTerm\"
      activate
      create window with default profile command \"$script\"
    end tell"
    return 0
  fi

  osascript -e "tell application \"Terminal\"
    activate
    do script \"$script\"
  end tell"
}

launch_with_terminal "$TMP_SCRIPT"
