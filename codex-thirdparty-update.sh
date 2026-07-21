#!/bin/bash

# Safely refresh the isolated Codex ThirdParty app from the official ChatGPT app.
# Chat history, credentials, and model settings live outside the app bundle and
# are intentionally not touched by this updater.

set -Eeuo pipefail

OFFICIAL_CODEX_APP="${OFFICIAL_CODEX_APP:-/Applications/ChatGPT.app}"
THIRDPARTY_CODEX_APP="${THIRDPARTY_CODEX_APP:-$HOME/Applications/Codex ThirdParty.app}"
THIRDPARTY_APP_MARKER="${THIRDPARTY_APP_MARKER:-$HOME/.codex-thirdparty/.thirdparty-app-source-build}"
THIRDPARTY_USER_DATA_DIR="${THIRDPARTY_USER_DATA_DIR:-$HOME/Library/Application Support/Codex-ThirdParty}"
UPDATE_LOCK_DIR="${UPDATE_LOCK_DIR:-$HOME/.codex-thirdparty/.thirdparty-app-update.lock}"
UPDATE_LOG_FILE="${UPDATE_LOG_FILE:-/tmp/codex-thirdparty-update.log}"
DITTO_BIN="${DITTO_BIN:-/usr/bin/ditto}"
PLUTIL_BIN="${PLUTIL_BIN:-/usr/bin/plutil}"
CODESIGN_BIN="${CODESIGN_BIN:-/usr/bin/codesign}"

log_update() {
  local message="$*"
  printf '%s\n' "$message"
  mkdir -p "$(dirname "$UPDATE_LOG_FILE")"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$message" >>"$UPDATE_LOG_FILE"
}

app_version_fingerprint() {
  local app="$1"
  local plist="$app/Contents/Info.plist"
  local version
  local build
  version="$($PLUTIL_BIN -extract CFBundleShortVersionString raw "$plist")"
  build="$($PLUTIL_BIN -extract CFBundleVersion raw "$plist")"
  printf '%s|%s' "$version" "$build"
}

app_bundle_identifier() {
  local app="$1"
  "$PLUTIL_BIN" -extract CFBundleIdentifier raw "$app/Contents/Info.plist"
}

thirdparty_instance_running() {
  local app_binary
  if [ "${THIRDPARTY_INSTANCE_RUNNING:-}" = "1" ]; then
    return 0
  fi
  if [ "${THIRDPARTY_INSTANCE_RUNNING:-}" = "0" ]; then
    return 1
  fi

  app_binary="$THIRDPARTY_CODEX_APP/Contents/MacOS/ChatGPT"
  ps -axo command= 2>/dev/null | awk -v app_binary="$app_binary" -v user_data="$THIRDPARTY_USER_DATA_DIR" '
    index($0, app_binary) == 1 && index($0, "--user-data-dir=" user_data) { found = 1 }
    END { exit(found ? 0 : 1) }
  '
}

needs_app_refresh() {
  local source_fingerprint
  local clone_fingerprint
  local clone_bundle_id
  local marker_fingerprint
  [ -x "$OFFICIAL_CODEX_APP/Contents/MacOS/ChatGPT" ] || return 2
  [ -x "$THIRDPARTY_CODEX_APP/Contents/MacOS/ChatGPT" ] || return 0

  source_fingerprint="$(app_version_fingerprint "$OFFICIAL_CODEX_APP" 2>/dev/null)" || return 2
  clone_fingerprint="$(app_version_fingerprint "$THIRDPARTY_CODEX_APP" 2>/dev/null)" || return 0
  clone_bundle_id="$(app_bundle_identifier "$THIRDPARTY_CODEX_APP" 2>/dev/null)" || return 0
  marker_fingerprint=""
  [ ! -f "$THIRDPARTY_APP_MARKER" ] || marker_fingerprint="$(cat "$THIRDPARTY_APP_MARKER")"

  [ "$source_fingerprint" != "$clone_fingerprint" ] && return 0
  [ "$clone_bundle_id" != "com.openai.codex.thirdparty" ] && return 0
  [ "$marker_fingerprint" != "$source_fingerprint" ] && return 0
  return 1
}

write_version_marker() {
  local fingerprint="$1"
  local marker_dir
  local marker_tmp
  marker_dir="$(dirname "$THIRDPARTY_APP_MARKER")"
  mkdir -p "$marker_dir"
  marker_tmp="$(mktemp "$marker_dir/.thirdparty-app-source-build.XXXXXX")"
  printf '%s\n' "$fingerprint" >"$marker_tmp"
  mv "$marker_tmp" "$THIRDPARTY_APP_MARKER"
}

validate_update_paths() {
  case "$OFFICIAL_CODEX_APP" in
    /*.app) ;;
    *) return 1 ;;
  esac
  case "$THIRDPARTY_CODEX_APP" in
    /*.app) ;;
    *) return 1 ;;
  esac
  [ "$OFFICIAL_CODEX_APP" != "$THIRDPARTY_CODEX_APP" ]
}

acquire_update_lock() {
  local existing_pid=""

  if mkdir "$UPDATE_LOCK_DIR" 2>/dev/null; then
    return 0
  fi

  if [ -f "$UPDATE_LOCK_DIR/pid" ]; then
    existing_pid="$(cat "$UPDATE_LOCK_DIR/pid" 2>/dev/null || true)"
  fi
  case "$existing_pid" in
    ''|*[!0-9]*) ;;
    *)
      if kill -0 "$existing_pid" 2>/dev/null; then
        return 1
      fi
      ;;
  esac

  rm -f "$UPDATE_LOCK_DIR/pid" 2>/dev/null || return 1
  rmdir "$UPDATE_LOCK_DIR" 2>/dev/null || return 1
  mkdir "$UPDATE_LOCK_DIR" 2>/dev/null
}

sync_app_clone() (
  staging_dir=""
  staging_app=""
  previous_app=""
  replacement_installed=0
  lock_owned=0
  local refresh_status
  local source_fingerprint_before
  local target_parent
  local target_name
  local staging_plist
  local source_fingerprint_after
  local staging_fingerprint
  local staging_bundle_id
  local installed_fingerprint
  local installed_bundle_id

  cleanup_sync() {
    local cleanup_status=$?
    local failed_app
    trap - EXIT INT TERM

    if [ "$cleanup_status" -ne 0 ] && [ "${replacement_installed:-0}" = "1" ]; then
      failed_app="${staging_dir:-}/failed-replacement.app"
      if [ -e "$THIRDPARTY_CODEX_APP" ]; then
        mv "$THIRDPARTY_CODEX_APP" "$failed_app" 2>/dev/null || true
      fi
      if [ -d "${previous_app:-}" ]; then
        mv "$previous_app" "$THIRDPARTY_CODEX_APP" 2>/dev/null || true
      fi
    fi

    if [ -n "${staging_dir:-}" ] && [ -d "$staging_dir" ]; then
      rm -rf "$staging_dir"
    fi
    if [ "${lock_owned:-0}" = "1" ]; then
      rm -f "$UPDATE_LOCK_DIR/pid"
      rmdir "$UPDATE_LOCK_DIR" 2>/dev/null || true
    fi
    exit "$cleanup_status"
  }
  trap cleanup_sync EXIT INT TERM

  if ! validate_update_paths; then
    log_update "status=failed reason=unsafe-app-paths"
    exit 64
  fi

  if needs_app_refresh; then
    refresh_status=0
  else
    refresh_status=$?
  fi

  if [ "$refresh_status" -eq 1 ]; then
    log_update "status=current version=$(app_version_fingerprint "$OFFICIAL_CODEX_APP")"
    exit 0
  fi
  if [ "$refresh_status" -ne 0 ]; then
    log_update "status=failed reason=official-app-unavailable path=$OFFICIAL_CODEX_APP"
    exit 2
  fi

  source_fingerprint_before="$(app_version_fingerprint "$OFFICIAL_CODEX_APP")"

  if thirdparty_instance_running; then
    log_update "status=deferred reason=thirdparty-running available=$source_fingerprint_before"
    exit 0
  fi

  mkdir -p "$(dirname "$UPDATE_LOCK_DIR")"
  if ! acquire_update_lock; then
    log_update "status=deferred reason=update-already-running"
    exit 0
  fi
  lock_owned=1
  printf '%s\n' "$$" >"$UPDATE_LOCK_DIR/pid"

  target_parent="$(dirname "$THIRDPARTY_CODEX_APP")"
  target_name="$(basename "$THIRDPARTY_CODEX_APP")"
  mkdir -p "$target_parent"
  staging_dir="$(mktemp -d "$target_parent/.codex-thirdparty-update.XXXXXX")"
  staging_app="$staging_dir/$target_name"
  previous_app="$staging_dir/previous.app"

  log_update "status=copying source=$source_fingerprint_before"
  if ! "$DITTO_BIN" --rsrc --extattr "$OFFICIAL_CODEX_APP" "$staging_app"; then
    log_update "status=failed reason=copy"
    exit 3
  fi

  staging_plist="$staging_app/Contents/Info.plist"
  "$PLUTIL_BIN" -replace CFBundleIdentifier -string com.openai.codex.thirdparty "$staging_plist"
  "$PLUTIL_BIN" -replace CFBundleName -string 'Codex ThirdParty' "$staging_plist"
  "$PLUTIL_BIN" -replace CFBundleDisplayName -string 'Codex ThirdParty' "$staging_plist"
  "$PLUTIL_BIN" -remove CFBundleAlternateNames "$staging_plist" 2>/dev/null || true

  if ! "$CODESIGN_BIN" --force --deep --sign - "$staging_app"; then
    log_update "status=failed reason=signing"
    exit 4
  fi
  if ! "$CODESIGN_BIN" --verify --deep --strict "$staging_app"; then
    log_update "status=failed reason=staging-signature-verification"
    exit 4
  fi

  source_fingerprint_after="$(app_version_fingerprint "$OFFICIAL_CODEX_APP")"
  if [ "$source_fingerprint_before" != "$source_fingerprint_after" ]; then
    log_update "status=failed reason=official-app-changed-during-copy before=$source_fingerprint_before after=$source_fingerprint_after"
    exit 3
  fi

  staging_fingerprint="$(app_version_fingerprint "$staging_app")"
  staging_bundle_id="$(app_bundle_identifier "$staging_app")"
  if [ "$staging_fingerprint" != "$source_fingerprint_before" ] || [ "$staging_bundle_id" != "com.openai.codex.thirdparty" ]; then
    log_update "status=failed reason=staging-verification"
    exit 4
  fi

  if [ -e "$THIRDPARTY_CODEX_APP" ]; then
    mv "$THIRDPARTY_CODEX_APP" "$previous_app"
    replacement_installed=1
  fi
  if ! mv "$staging_app" "$THIRDPARTY_CODEX_APP"; then
    log_update "status=failed reason=install-move"
    exit 5
  fi
  replacement_installed=1

  if ! "$CODESIGN_BIN" --verify --deep --strict "$THIRDPARTY_CODEX_APP"; then
    log_update "status=failed reason=installed-signature-verification"
    exit 5
  fi
  installed_fingerprint="$(app_version_fingerprint "$THIRDPARTY_CODEX_APP")"
  installed_bundle_id="$(app_bundle_identifier "$THIRDPARTY_CODEX_APP")"
  if [ "$installed_fingerprint" != "$source_fingerprint_before" ] || [ "$installed_bundle_id" != "com.openai.codex.thirdparty" ]; then
    log_update "status=failed reason=installed-verification"
    exit 5
  fi

  write_version_marker "$source_fingerprint_before"
  replacement_installed=0
  log_update "status=updated version=$source_fingerprint_before"
)

check_update_status() {
  local check_result
  if needs_app_refresh; then
    check_result=0
  else
    check_result=$?
  fi

  if [ "$check_result" -eq 0 ]; then
    printf 'outdated official=%s thirdparty=%s\n' \
      "$(app_version_fingerprint "$OFFICIAL_CODEX_APP")" \
      "$(app_version_fingerprint "$THIRDPARTY_CODEX_APP" 2>/dev/null || printf missing)"
    return 10
  fi
  if [ "$check_result" -eq 1 ]; then
    printf 'current version=%s\n' "$(app_version_fingerprint "$OFFICIAL_CODEX_APP")"
    return 0
  fi

  printf 'unavailable official=%s\n' "$OFFICIAL_CODEX_APP" >&2
  return 2
}

main() {
  case "${1:---update}" in
    --update)
      sync_app_clone
      ;;
    --check)
      check_update_status
      ;;
    *)
      printf 'Usage: %s [--check|--update]\n' "$0" >&2
      return 64
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
