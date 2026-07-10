#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Codex ThirdParty
# @raycast.mode silent

# Optional parameters:
# @raycast.icon 🧩
# @raycast.packageName Codex

# Documentation:
# @raycast.description 启动 ChatGPT 内的第三方 API 版 Codex
# @raycast.author suda

set -Eeuo pipefail

CODEX_APP="/Applications/ChatGPT.app"
CODEX_BIN="$CODEX_APP/Contents/MacOS/ChatGPT"
CODEX_HOME_DIR="$HOME/.codex-thirdparty"
OFFICIAL_CODEX_HOME="$HOME/.codex"
USER_DATA_DIR="$HOME/Library/Application Support/Codex-ThirdParty"
LAUNCH_CWD="$HOME/Documents/Codex"
LOG_FILE="/tmp/codex-thirdparty.log"
CC_SWITCH_DB="$HOME/.cc-switch/cc-switch.db"
CC_SWITCH_PROVIDER_ID="default"

mkdir -p "$CODEX_HOME_DIR" "$USER_DATA_DIR" "$LAUNCH_CWD"

log_event() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG_FILE"
}

trap 'log_event "error status=$? line=$LINENO command=$BASH_COMMAND"' ERR

sqlite_table_exists() {
  db_path="$1"
  table_name="$2"
  sqlite3 -batch -noheader "$db_path" \
    "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = '$table_name';" 2>/dev/null |
    grep -qx '1'
}

log_event "triggered ppid=$PPID"

if [ ! -x "$CODEX_BIN" ]; then
  echo "ChatGPT App not found: $CODEX_BIN"
  log_event "missing ChatGPT binary path=$CODEX_BIN"
  exit 1
fi

import_official_history() {
  [ -d "$OFFICIAL_CODEX_HOME" ] || return 0

  if command -v rsync >/dev/null 2>&1; then
    [ -d "$OFFICIAL_CODEX_HOME/sessions" ] && rsync -a --ignore-existing "$OFFICIAL_CODEX_HOME/sessions/" "$CODEX_HOME_DIR/sessions/"
    [ -d "$OFFICIAL_CODEX_HOME/archived_sessions" ] && mkdir -p "$CODEX_HOME_DIR/archived_sessions" && rsync -a --ignore-existing "$OFFICIAL_CODEX_HOME/archived_sessions/" "$CODEX_HOME_DIR/archived_sessions/"
  fi

  for name in session_index.jsonl history.jsonl; do
    src="$OFFICIAL_CODEX_HOME/$name"
    dest="$CODEX_HOME_DIR/$name"
    [ -f "$src" ] || continue
    touch "$dest"
    tmp="$dest.tmp.$$"
    awk '!seen[$0]++' "$dest" "$src" >"$tmp" && mv "$tmp" "$dest"
  done

  if command -v sqlite3 >/dev/null 2>&1 && [ -f "$OFFICIAL_CODEX_HOME/state_5.sqlite" ]; then
    if [ ! -f "$CODEX_HOME_DIR/state_5.sqlite" ]; then
      sqlite3 "$OFFICIAL_CODEX_HOME/state_5.sqlite" ".backup '$CODEX_HOME_DIR/state_5.sqlite'"
      sqlite3 "$CODEX_HOME_DIR/state_5.sqlite" "UPDATE threads SET rollout_path = replace(rollout_path, '$OFFICIAL_CODEX_HOME', '$CODEX_HOME_DIR');"
      hide_internal_import_noise
      rebuild_session_index
      return 0
    fi

    sqlite3 "$CODEX_HOME_DIR/state_5.sqlite" >/dev/null <<SQL
PRAGMA busy_timeout = 5000;
PRAGMA foreign_keys = OFF;
ATTACH DATABASE '$OFFICIAL_CODEX_HOME/state_5.sqlite' AS official;
INSERT OR IGNORE INTO threads (
    id,
    rollout_path,
    created_at,
    updated_at,
    source,
    model_provider,
    cwd,
    title,
    sandbox_policy,
    approval_mode,
    tokens_used,
    has_user_event,
    archived,
    archived_at,
    git_sha,
    git_branch,
    git_origin_url,
    cli_version,
    first_user_message,
    agent_nickname,
    agent_role,
    memory_mode,
    model,
    reasoning_effort,
    agent_path,
    created_at_ms,
    updated_at_ms,
    thread_source,
    preview,
    recency_at,
    recency_at_ms,
    history_mode
  )
  SELECT
    id,
    replace(rollout_path, '$OFFICIAL_CODEX_HOME', '$CODEX_HOME_DIR'),
    created_at,
    updated_at,
    source,
    model_provider,
    cwd,
    title,
    sandbox_policy,
    approval_mode,
    tokens_used,
    has_user_event,
    archived,
    archived_at,
    git_sha,
    git_branch,
    git_origin_url,
    cli_version,
    first_user_message,
    agent_nickname,
    agent_role,
    memory_mode,
    model,
    reasoning_effort,
    agent_path,
    created_at_ms,
    updated_at_ms,
    thread_source,
    preview,
    recency_at,
    recency_at_ms,
    history_mode
  FROM official.threads;
INSERT OR IGNORE INTO thread_dynamic_tools SELECT * FROM official.thread_dynamic_tools;
INSERT OR IGNORE INTO thread_spawn_edges SELECT * FROM official.thread_spawn_edges;
DETACH DATABASE official;
SQL

    if sqlite_table_exists "$CODEX_HOME_DIR/state_5.sqlite" stage1_outputs &&
      sqlite_table_exists "$OFFICIAL_CODEX_HOME/state_5.sqlite" stage1_outputs; then
      sqlite3 "$CODEX_HOME_DIR/state_5.sqlite" >/dev/null <<SQL
PRAGMA busy_timeout = 5000;
ATTACH DATABASE '$OFFICIAL_CODEX_HOME/state_5.sqlite' AS official;
INSERT OR IGNORE INTO stage1_outputs SELECT * FROM official.stage1_outputs;
DETACH DATABASE official;
SQL
    else
      log_event "skip optional table stage1_outputs"
    fi
  fi

  hide_internal_import_noise
  rebuild_session_index
}

hide_internal_import_noise() {
  command -v sqlite3 >/dev/null 2>&1 || return 0
  [ -f "$CODEX_HOME_DIR/state_5.sqlite" ] || return 0

  mkdir -p "$CODEX_HOME_DIR/archived_sessions"

  sqlite3 -batch -noheader -separator $'\t' "$CODEX_HOME_DIR/state_5.sqlite" <<SQL | while IFS=$'\t' read -r rollout_path; do
SELECT rollout_path
FROM threads
WHERE (
    cwd LIKE '$HOME/Library/Application Support/cn.herear.salon/%'
    OR cwd = '$HOME/Her工作间/后台会话'
    OR thread_source = 'subagent'
    OR source LIKE '{"subagent":%'
    OR coalesce(first_user_message, preview, title, '') LIKE '<her_runtime_context>%'
    OR coalesce(first_user_message, preview, title, '') LIKE '你是 Her PA 潜意识层的 Sentry%'
    OR (
      cwd = '$HOME/Her工作间'
      AND coalesce(first_user_message, preview, title, '') LIKE 'Generate a very short title%'
    )
  )
  AND rollout_path LIKE '$CODEX_HOME_DIR/sessions/%';
SQL
    [ -n "$rollout_path" ] || continue
    archived_path="$CODEX_HOME_DIR/archived_sessions/${rollout_path#"$CODEX_HOME_DIR/sessions/"}"
    mkdir -p "$(dirname "$archived_path")"
    if [ -f "$rollout_path" ]; then
      mv -f "$rollout_path" "$archived_path"
    fi
  done

  sqlite3 "$CODEX_HOME_DIR/state_5.sqlite" >/dev/null <<SQL
PRAGMA busy_timeout = 5000;
UPDATE threads
SET
  archived = 1,
  archived_at = coalesce(archived_at, strftime('%s', 'now')),
  rollout_path = replace(rollout_path, '$CODEX_HOME_DIR/sessions/', '$CODEX_HOME_DIR/archived_sessions/')
WHERE (
    cwd LIKE '$HOME/Library/Application Support/cn.herear.salon/%'
    OR cwd = '$HOME/Her工作间/后台会话'
    OR thread_source = 'subagent'
    OR source LIKE '{"subagent":%'
    OR coalesce(first_user_message, preview, title, '') LIKE '<her_runtime_context>%'
    OR coalesce(first_user_message, preview, title, '') LIKE '你是 Her PA 潜意识层的 Sentry%'
    OR (
      cwd = '$HOME/Her工作间'
      AND coalesce(first_user_message, preview, title, '') LIKE 'Generate a very short title%'
    )
  );
SQL
}

rebuild_session_index() {
  command -v sqlite3 >/dev/null 2>&1 || return 0
  [ -f "$CODEX_HOME_DIR/state_5.sqlite" ] || return 0

  tmp="$CODEX_HOME_DIR/session_index.jsonl.tmp.$$"
  sqlite3 -batch -noheader "$CODEX_HOME_DIR/state_5.sqlite" >"$tmp" <<'SQL'
WITH indexed_threads AS (
  SELECT
    id,
    coalesce(updated_at_ms, updated_at * 1000) AS updated_at_sort,
    trim(
      replace(
        replace(
          coalesce(nullif(title, ''), nullif(first_user_message, ''), nullif(preview, ''), id),
          char(10),
          ' '
        ),
        char(13),
        ' '
      )
    ) AS thread_name
  FROM threads
  WHERE coalesce(id, '') != ''
    AND archived = 0
)
SELECT json_object(
  'id',
  id,
  'thread_name',
  CASE
    WHEN length(thread_name) > 180 THEN substr(thread_name, 1, 177) || '...'
    ELSE thread_name
  END,
  'updated_at',
  strftime('%Y-%m-%dT%H:%M:%fZ', updated_at_sort / 1000.0, 'unixepoch')
)
FROM indexed_threads
ORDER BY updated_at_sort, id;
SQL

  if [ -s "$tmp" ]; then
    mv "$tmp" "$CODEX_HOME_DIR/session_index.jsonl"
  else
    rm -f "$tmp"
  fi
}

sync_thirdparty_projectless_threads() {
  command -v node >/dev/null 2>&1 || return 0
  command -v sqlite3 >/dev/null 2>&1 || return 0
  [ -f "$CODEX_HOME_DIR/state_5.sqlite" ] || return 0

  CODEX_HOME_DIR="$CODEX_HOME_DIR" node >/dev/null 2>>"$LOG_FILE" <<'NODE'
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const codexHome = process.env.CODEX_HOME_DIR;
const dbPath = path.join(codexHome, "state_5.sqlite");
const statePath = path.join(codexHome, ".codex-global-state.json");

const rows = execFileSync(
  "sqlite3",
  [
    "-batch",
    "-separator",
    "\t",
    dbPath,
    `
SELECT id, cwd
FROM threads
WHERE archived = 0
  AND coalesce(id, '') != ''
  AND coalesce(cwd, '') != ''
ORDER BY coalesce(updated_at_ms, updated_at * 1000) DESC, id;
`.trim(),
  ],
  { encoding: "utf8" },
)
  .split(/\r?\n/)
  .map((line) => line.trim())
  .filter(Boolean)
  .map((line) => {
    const [id, cwd] = line.split("\t");
    return { id, cwd };
  })
  .filter((row) => row.id && row.cwd);

const knownWorkspaceRows = execFileSync(
  "sqlite3",
  [
    "-batch",
    "-separator",
    "\t",
    dbPath,
    `
SELECT id, cwd
FROM threads
WHERE coalesce(id, '') != ''
  AND coalesce(cwd, '') != '';
`.trim(),
  ],
  { encoding: "utf8" },
)
  .split(/\r?\n/)
  .map((line) => line.trim())
  .filter(Boolean)
  .map((line) => {
    const [id, cwd] = line.split("\t");
    return { id, cwd };
  })
  .filter((row) => row.id && row.cwd);

if (rows.length === 0) {
  process.exit(0);
}

let state = {};
try {
  state = JSON.parse(fs.readFileSync(statePath, "utf8"));
} catch {
  state = {};
}

const cwdById = new Map(knownWorkspaceRows.map(({ id, cwd }) => [id, cwd]));
const cwdOrder = [...new Set(rows.map(({ cwd }) => cwd))];

const existingProjectless = Array.isArray(state["projectless-thread-ids"])
  ? state["projectless-thread-ids"].map(String)
  : [];
const nextProjectless = existingProjectless.filter((id) => !cwdById.has(id));

const existingHints =
  state["thread-workspace-root-hints"] &&
  typeof state["thread-workspace-root-hints"] === "object" &&
  !Array.isArray(state["thread-workspace-root-hints"])
    ? state["thread-workspace-root-hints"]
    : {};
const nextHints = { ...existingHints };
for (const { id, cwd } of rows) {
  nextHints[id] = cwd;
}

const existingProjectOrder = Array.isArray(state["project-order"])
  ? state["project-order"].map(String)
  : [];
const nextProjectOrder = [...new Set([...cwdOrder, ...existingProjectOrder])];

const existingSavedRoots = Array.isArray(state["electron-saved-workspace-roots"])
  ? state["electron-saved-workspace-roots"].map(String)
  : [];
const nextSavedRoots = [...new Set([...cwdOrder, ...existingSavedRoots])];

const sameArray = (a, b) => a.length === b.length && a.every((value, index) => value === b[index]);
if (
  sameArray(nextProjectless, existingProjectless) &&
  sameArray(nextProjectOrder, existingProjectOrder) &&
  sameArray(nextSavedRoots, existingSavedRoots) &&
  JSON.stringify(nextHints) === JSON.stringify(existingHints)
) {
  process.exit(0);
}

if (nextProjectless.length > 0) {
  state["projectless-thread-ids"] = nextProjectless;
} else {
  delete state["projectless-thread-ids"];
}
state["thread-workspace-root-hints"] = nextHints;
state["project-order"] = nextProjectOrder;
state["electron-saved-workspace-roots"] = nextSavedRoots;
const raw = JSON.stringify(state);
const tmpPath = `${statePath}.tmp-${process.pid}-${Date.now()}`;
fs.writeFileSync(tmpPath, raw, "utf8");
fs.renameSync(tmpPath, statePath);
fs.writeFileSync(`${statePath}.bak`, raw, "utf8");
NODE
}

thirdparty_main_pid() {
  ps -axo pid=,ppid=,command= 2>/dev/null | awk \
    -v app_bin="$CODEX_BIN" \
    -v framework_dir="$CODEX_APP/Contents/Frameworks/" \
    -v dir="$USER_DATA_DIR" '
    index($0, app_bin " --user-data-dir=" dir) { main_pid = $1 }
    index($0, "--user-data-dir=" dir) && index($0, framework_dir) { helper_parent_pid = $2 }
    END {
      if (main_pid) print main_pid;
      else if (helper_parent_pid) print helper_parent_pid;
    }
  '
}

visible_window_count() {
  /usr/bin/osascript -l JavaScript -e '
    ObjC.import("CoreGraphics");
    function run(argv) {
      const pid = Number(argv[0]);
      const windows = ObjC.castRefToObject(
        $.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)
      );
      let count = 0;
      for (let index = 0; index < windows.count; index++) {
        const win = windows.objectAtIndex(index);
        if (Number(ObjC.unwrap(win.objectForKey("kCGWindowOwnerPID"))) === pid) {
          count++;
        }
      }
      return String(count);
    }
  ' "$1" 2>>"$LOG_FILE"
}

activate_existing_instance() {
  pid="$(thirdparty_main_pid)"
  [ -n "$pid" ] || return 1

  if ! /usr/bin/osascript \
    -e 'on run argv' \
    -e 'set targetPID to (item 1 of argv) as integer' \
    -e 'tell application "System Events" to set frontmost of first process whose unix id is targetPID to true' \
    -e 'end run' \
    "$pid" >/dev/null 2>>"$LOG_FILE"; then
    printf '%s failed to activate existing Codex ThirdParty pid=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pid" >>"$LOG_FILE"
    return 1
  else
    windows="$(visible_window_count "$pid" || true)"
    log_event "activated existing instance pid=$pid windows=${windows:-unknown}"
    if [ "${windows:-unknown}" = "0" ]; then
      log_event "existing instance has no visible windows; reopening"
      launch_instance
    fi
  fi

  return 0
}

launch_instance() {
  log_event "launching new instance"
  open \
    --env "CODEX_HOME=$CODEX_HOME_DIR" \
    --env "CODEX_ELECTRON_USER_DATA_PATH=$USER_DATA_DIR" \
    -na "$CODEX_APP" \
    --args "--user-data-dir=$USER_DATA_DIR" >/dev/null 2>>"$LOG_FILE"
  log_event "launch command sent"
}

sync_cc_switch_api_key() {
  if ! command -v sqlite3 >/dev/null 2>&1 || [ ! -r "$CC_SWITCH_DB" ]; then
    log_event "cc-switch database unavailable; keeping existing third-party credential"
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    log_event "jq unavailable; keeping existing third-party credential"
    return 0
  fi

  cc_switch_key="$(sqlite3 -batch -noheader "$CC_SWITCH_DB" \
    "SELECT json_extract(settings_config, '$.auth.OPENAI_API_KEY') FROM providers WHERE app_type = 'codex' AND id = '$CC_SWITCH_PROVIDER_ID' LIMIT 1;" \
    2>/dev/null || true)"

  if [ -z "$cc_switch_key" ]; then
    log_event "cc-switch provider id=$CC_SWITCH_PROVIDER_ID has no API key; keeping existing third-party credential"
    return 0
  fi

  auth_file="$CODEX_HOME_DIR/auth.json"
  current_key=""
  if [ -f "$auth_file" ]; then
    current_key="$(jq -r '.OPENAI_API_KEY // empty' "$auth_file" 2>/dev/null || true)"
  fi

  if [ "$current_key" = "$cc_switch_key" ]; then
    log_event "cc-switch API key already synchronized"
    unset cc_switch_key current_key
    return 0
  fi

  umask 077
  auth_tmp="$(mktemp "$CODEX_HOME_DIR/auth.json.tmp.XXXXXX")"
  if [ -f "$auth_file" ]; then
    OPENAI_API_KEY="$cc_switch_key" jq '.OPENAI_API_KEY = env.OPENAI_API_KEY' "$auth_file" >"$auth_tmp"
  else
    OPENAI_API_KEY="$cc_switch_key" jq -n '{OPENAI_API_KEY: env.OPENAI_API_KEY}' >"$auth_tmp"
  fi
  chmod 600 "$auth_tmp"
  mv "$auth_tmp" "$auth_file"
  log_event "synchronized API key from cc-switch provider id=$CC_SWITCH_PROVIDER_ID"
  unset cc_switch_key current_key auth_tmp
}

if [ "${CODEX_LAUNCH_DRY_RUN:-}" = "1" ]; then
  echo "CODEX_HOME=$CODEX_HOME_DIR"
  echo "CODEX_ELECTRON_USER_DATA_PATH=$USER_DATA_DIR"
  echo "PWD=$LAUNCH_CWD"
  echo "$CODEX_BIN"
  exit 0
fi

sync_cc_switch_api_key

set +e
import_official_history
import_status=$?
set -e
if [ "$import_status" -ne 0 ]; then
  log_event "official history import failed status=$import_status; continuing launch"
fi

API_PROXY_SCRIPT="$CODEX_HOME_DIR/api-proxy.mjs"
API_PROXY_PORT=18360
API_PROXY_PID_FILE="$CODEX_HOME_DIR/.api-proxy.pid"

ensure_api_proxy() {
  if [ -f "$API_PROXY_PID_FILE" ]; then
    local old_pid
    old_pid="$(cat "$API_PROXY_PID_FILE" 2>/dev/null)"
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      log_event "api-proxy already running pid=$old_pid"
      return 0
    fi
  fi

  if [ ! -f "$API_PROXY_SCRIPT" ]; then
    log_event "api-proxy script not found: $API_PROXY_SCRIPT"
    return 1
  fi

  nohup node "$API_PROXY_SCRIPT" >>"$LOG_FILE" 2>&1 &
  echo $! >"$API_PROXY_PID_FILE"
  log_event "api-proxy started pid=$! port=$API_PROXY_PORT"
}

ensure_api_proxy

cd "$LAUNCH_CWD"

if ! activate_existing_instance; then
  sync_thirdparty_projectless_threads
  launch_instance
fi
