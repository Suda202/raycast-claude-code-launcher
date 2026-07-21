#!/bin/bash

set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATE_SCRIPT="$REPO_DIR/codex-thirdparty-update.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-thirdparty-update-tests.XXXXXX")"
PASS_COUNT=0

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [ "$expected" = "$actual" ] || fail "$message (expected=$expected actual=$actual)"
}

assert_file_contains() {
  local path="$1"
  local expected="$2"
  grep -Fq "$expected" "$path" || fail "$path does not contain: $expected"
}

plist_value() {
  local app="$1"
  local key="$2"
  /usr/bin/plutil -extract "$key" raw "$app/Contents/Info.plist"
}

create_app() {
  local app="$1"
  local version="$2"
  local build="$3"
  local bundle_id="$4"
  local name="$5"

  mkdir -p "$app/Contents/MacOS"
  /usr/bin/plutil -create xml1 "$app/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleVersion -string "$build" "$app/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$bundle_id" "$app/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleName -string "$name" "$app/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleDisplayName -string "$name" "$app/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleExecutable -string ChatGPT "$app/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleAlternateNames -xml '<array><string>Codex</string></array>' "$app/Contents/Info.plist"
  printf '#!/bin/sh\nexit 0\n' >"$app/Contents/MacOS/ChatGPT"
  chmod +x "$app/Contents/MacOS/ChatGPT"
}

make_tool_stubs() {
  local case_dir="$1"
  mkdir -p "$case_dir/bin"

  cat >"$case_dir/bin/ditto" <<'STUB'
#!/bin/bash
set -Eeuo pipefail
source_app="${@: -2:1}"
target_app="${@: -1}"
printf 'ditto %s %s\n' "$source_app" "$target_app" >>"$TOOL_LOG"
cp -R "$source_app" "$target_app"
if [ "${MUTATE_SOURCE_AFTER_COPY:-0}" = "1" ]; then
  /usr/bin/plutil -replace CFBundleVersion -string 9999 "$source_app/Contents/Info.plist"
fi
STUB

  cat >"$case_dir/bin/codesign" <<'STUB'
#!/bin/bash
set -Eeuo pipefail
printf 'codesign %s\n' "$*" >>"$TOOL_LOG"
if [ "${FAIL_CODESIGN:-0}" = "1" ]; then
  exit 42
fi
if [[ " $* " == *" --verify "* ]] && [ -n "${FAIL_VERIFY_CALL:-}" ]; then
  verify_count=0
  [ ! -f "$VERIFY_COUNT_FILE" ] || verify_count="$(cat "$VERIFY_COUNT_FILE")"
  verify_count=$((verify_count + 1))
  printf '%s\n' "$verify_count" >"$VERIFY_COUNT_FILE"
  if [ "$verify_count" = "$FAIL_VERIFY_CALL" ]; then
    exit 43
  fi
fi
exit 0
STUB

  chmod +x "$case_dir/bin/ditto" "$case_dir/bin/codesign"
}

run_sync() {
  local case_dir="$1"
  shift

  OFFICIAL_CODEX_APP="$case_dir/Official.app" \
  THIRDPARTY_CODEX_APP="$case_dir/Codex ThirdParty.app" \
  THIRDPARTY_APP_MARKER="$case_dir/source-build" \
  UPDATE_LOCK_DIR="$case_dir/update.lock" \
  UPDATE_LOG_FILE="$case_dir/update.log" \
  DITTO_BIN="$case_dir/bin/ditto" \
  CODESIGN_BIN="$case_dir/bin/codesign" \
  PLUTIL_BIN="/usr/bin/plutil" \
  TOOL_LOG="$case_dir/tools.log" \
  VERIFY_COUNT_FILE="$case_dir/verify-count" \
  "$@" \
  bash -c 'source "$1"; sync_app_clone' bash "$UPDATE_SCRIPT"
}

test_current_version_is_noop() {
  local case_dir="$TEST_ROOT/current"
  make_tool_stubs "$case_dir"
  create_app "$case_dir/Official.app" 26.715.70719 5650 com.openai.codex ChatGPT
  create_app "$case_dir/Codex ThirdParty.app" 26.715.70719 5650 com.openai.codex.thirdparty 'Codex ThirdParty'
  printf '26.715.70719|5650\n' >"$case_dir/source-build"

  run_sync "$case_dir"

  [ ! -e "$case_dir/tools.log" ] || fail 'up-to-date app should not invoke copy or signing tools'
  assert_eq 5650 "$(plist_value "$case_dir/Codex ThirdParty.app" CFBundleVersion)" 'current build changed'
}

test_outdated_app_updates_identity_and_marker() {
  local case_dir="$TEST_ROOT/outdated"
  make_tool_stubs "$case_dir"
  create_app "$case_dir/Official.app" 26.715.70719 5650 com.openai.codex ChatGPT
  create_app "$case_dir/Codex ThirdParty.app" 26.707.51957 5175 com.openai.codex.thirdparty 'Codex ThirdParty'
  printf '26.707.51957|5175\n' >"$case_dir/source-build"

  run_sync "$case_dir"

  assert_eq 5650 "$(plist_value "$case_dir/Codex ThirdParty.app" CFBundleVersion)" 'outdated build was not updated'
  assert_eq com.openai.codex.thirdparty "$(plist_value "$case_dir/Codex ThirdParty.app" CFBundleIdentifier)" 'bundle id was not isolated'
  assert_eq 'Codex ThirdParty' "$(plist_value "$case_dir/Codex ThirdParty.app" CFBundleDisplayName)" 'display name was not isolated'
  if /usr/bin/plutil -extract CFBundleAlternateNames raw "$case_dir/Codex ThirdParty.app/Contents/Info.plist" >/dev/null 2>&1; then
    fail 'official alternate name should be removed'
  fi
  assert_file_contains "$case_dir/source-build" '26.715.70719|5650'
  assert_file_contains "$case_dir/tools.log" 'codesign --verify --deep --strict'
}

test_running_app_defers_update() {
  local case_dir="$TEST_ROOT/running"
  make_tool_stubs "$case_dir"
  create_app "$case_dir/Official.app" 26.715.70719 5650 com.openai.codex ChatGPT
  create_app "$case_dir/Codex ThirdParty.app" 26.707.51957 5175 com.openai.codex.thirdparty 'Codex ThirdParty'

  run_sync "$case_dir" env THIRDPARTY_INSTANCE_RUNNING=1

  assert_eq 5175 "$(plist_value "$case_dir/Codex ThirdParty.app" CFBundleVersion)" 'running app should not be replaced'
  [ ! -e "$case_dir/tools.log" ] || fail 'running app should not invoke copy or signing tools'
}

test_signing_failure_preserves_old_app() {
  local case_dir="$TEST_ROOT/signing-failure"
  make_tool_stubs "$case_dir"
  create_app "$case_dir/Official.app" 26.715.70719 5650 com.openai.codex ChatGPT
  create_app "$case_dir/Codex ThirdParty.app" 26.707.51957 5175 com.openai.codex.thirdparty 'Codex ThirdParty'
  printf '26.707.51957|5175\n' >"$case_dir/source-build"

  if run_sync "$case_dir" env FAIL_CODESIGN=1; then
    fail 'signing failure should return non-zero'
  fi

  assert_eq 5175 "$(plist_value "$case_dir/Codex ThirdParty.app" CFBundleVersion)" 'signing failure replaced the old app'
  assert_file_contains "$case_dir/source-build" '26.707.51957|5175'
}

test_source_change_during_copy_preserves_old_app() {
  local case_dir="$TEST_ROOT/source-race"
  make_tool_stubs "$case_dir"
  create_app "$case_dir/Official.app" 26.715.70719 5650 com.openai.codex ChatGPT
  create_app "$case_dir/Codex ThirdParty.app" 26.707.51957 5175 com.openai.codex.thirdparty 'Codex ThirdParty'

  if run_sync "$case_dir" env MUTATE_SOURCE_AFTER_COPY=1; then
    fail 'source version race should return non-zero'
  fi

  assert_eq 5175 "$(plist_value "$case_dir/Codex ThirdParty.app" CFBundleVersion)" 'source race replaced the old app'
}

test_missing_app_is_created() {
  local case_dir="$TEST_ROOT/missing"
  make_tool_stubs "$case_dir"
  create_app "$case_dir/Official.app" 26.715.70719 5650 com.openai.codex ChatGPT

  run_sync "$case_dir"

  assert_eq 5650 "$(plist_value "$case_dir/Codex ThirdParty.app" CFBundleVersion)" 'missing app was not created'
  assert_eq com.openai.codex.thirdparty "$(plist_value "$case_dir/Codex ThirdParty.app" CFBundleIdentifier)" 'created app has the wrong bundle id'
}

test_installed_verification_failure_rolls_back() {
  local case_dir="$TEST_ROOT/rollback"
  make_tool_stubs "$case_dir"
  create_app "$case_dir/Official.app" 26.715.70719 5650 com.openai.codex ChatGPT
  create_app "$case_dir/Codex ThirdParty.app" 26.707.51957 5175 com.openai.codex.thirdparty 'Codex ThirdParty'

  if run_sync "$case_dir" env FAIL_VERIFY_CALL=2; then
    fail 'installed verification failure should return non-zero'
  fi

  assert_eq 5175 "$(plist_value "$case_dir/Codex ThirdParty.app" CFBundleVersion)" 'installed verification failure did not restore the old app'
}

test_concurrent_update_is_deferred() {
  local case_dir="$TEST_ROOT/concurrent"
  make_tool_stubs "$case_dir"
  create_app "$case_dir/Official.app" 26.715.70719 5650 com.openai.codex ChatGPT
  create_app "$case_dir/Codex ThirdParty.app" 26.707.51957 5175 com.openai.codex.thirdparty 'Codex ThirdParty'
  mkdir "$case_dir/update.lock"
  printf '%s\n' "$$" >"$case_dir/update.lock/pid"

  run_sync "$case_dir"

  assert_eq 5175 "$(plist_value "$case_dir/Codex ThirdParty.app" CFBundleVersion)" 'concurrent updater should not replace the app'
  [ ! -e "$case_dir/tools.log" ] || fail 'concurrent updater should not invoke copy or signing tools'
}

test_stale_lock_is_recovered() {
  local case_dir="$TEST_ROOT/stale-lock"
  make_tool_stubs "$case_dir"
  create_app "$case_dir/Official.app" 26.715.70719 5650 com.openai.codex ChatGPT
  create_app "$case_dir/Codex ThirdParty.app" 26.707.51957 5175 com.openai.codex.thirdparty 'Codex ThirdParty'
  mkdir "$case_dir/update.lock"
  printf '999999\n' >"$case_dir/update.lock/pid"

  run_sync "$case_dir"

  assert_eq 5650 "$(plist_value "$case_dir/Codex ThirdParty.app" CFBundleVersion)" 'stale lock was not recovered'
}

test_missing_app_failed_verification_leaves_no_broken_target() {
  local case_dir="$TEST_ROOT/missing-rollback"
  make_tool_stubs "$case_dir"
  create_app "$case_dir/Official.app" 26.715.70719 5650 com.openai.codex ChatGPT

  if run_sync "$case_dir" env FAIL_VERIFY_CALL=2; then
    fail 'missing target with failed verification should return non-zero'
  fi

  [ ! -e "$case_dir/Codex ThirdParty.app" ] || fail 'failed first install left a broken target app'
}

run_test() {
  local name="$1"
  "$name"
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS: %s\n' "$name"
}

run_test test_current_version_is_noop
run_test test_outdated_app_updates_identity_and_marker
run_test test_running_app_defers_update
run_test test_signing_failure_preserves_old_app
run_test test_source_change_during_copy_preserves_old_app
run_test test_missing_app_is_created
run_test test_installed_verification_failure_rolls_back
run_test test_concurrent_update_is_deferred
run_test test_stale_lock_is_recovered
run_test test_missing_app_failed_verification_leaves_no_broken_target

printf 'PASS: %s tests\n' "$PASS_COUNT"
