#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

failures=0

fail() {
  print -r -- "FAIL: $1" >&2
  failures=$((failures + 1))
}

assert_file() {
  [[ -f "$1" ]] || fail "expected file: $1"
}

assert_not_exists() {
  [[ ! -e "$1" ]] || fail "expected path to be removed: $1"
}

assert_exists() {
  [[ -e "$1" ]] || fail "expected path to exist: $1"
}

assert_contains() {
  # NOTE: do not name this local "path" — zsh ties $path to $PATH, and
  # shadowing it here silently breaks lookups (see PR discussion / commit
  # history for this file if that regresses again).
  local file_path="$1"
  local needle="$2"
  if ! grep -Fq -- "$needle" "$file_path" 2>/dev/null; then
    fail "expected $file_path to contain: $needle"
  fi
}

assert_not_contains() {
  local file_path="$1"
  local needle="$2"
  if [[ -f "$file_path" ]] && grep -Fq -- "$needle" "$file_path" 2>/dev/null; then
    fail "expected $file_path NOT to contain: $needle"
  fi
}

make_fixture() {
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/whatsapp-mcp-notifier-test.XXXXXX")"
  mkdir -p "$tmp/repo/scripts" "$tmp/repo/whatsapp-bridge/store" "$tmp/home" "$tmp/fakebin"

  cp "$REPO_ROOT/scripts/install-message-notifier-launchd-macos.sh" "$tmp/repo/scripts/"
  cp "$REPO_ROOT/scripts/uninstall-message-notifier-launchd-macos.sh" "$tmp/repo/scripts/"

  cat > "$tmp/fakebin/uname" <<'EOF'
#!/bin/sh
printf 'Darwin\n'
EOF

  cat > "$tmp/fakebin/id" <<'EOF'
#!/bin/sh
if [ "$1" = "-u" ]; then
  printf '501\n'
  exit 0
fi
/usr/bin/id "$@"
EOF

  cat > "$tmp/fakebin/launchctl" <<'EOF'
#!/bin/sh
printf 'launchctl %s\n' "$*" >> "$FAKE_CMD_LOG"
exit 0
EOF

  # Records every invocation (including the prompt, as the last argument) and
  # prints a canned summary, unless FAKE_CLAUDE_FAIL=1.
  cat > "$tmp/fakebin/claude" <<'EOF'
#!/bin/sh
printf 'claude %s\n' "$*" >> "$FAKE_CMD_LOG"
if [ "${FAKE_CLAUDE_FAIL:-0}" = "1" ]; then
  exit 1
fi
printf '%s' "${FAKE_CLAUDE_SUMMARY:-FAKE SUMMARY}"
EOF

  cat > "$tmp/fakebin/osascript" <<'EOF'
#!/bin/sh
printf 'osascript %s\n' "$*" >> "$FAKE_NOTIFY_LOG"
exit 0
EOF

  chmod +x "$tmp/fakebin/"*
  print -r -- "$tmp"
}

# Real sqlite3 (from PATH) builds a real messages.db, so the checker script's
# actual SQL is exercised end-to-end rather than mocked.
seed_db() {
  local db_path="$1"
  sqlite3 "$db_path" <<'SQL'
CREATE TABLE chats (jid TEXT PRIMARY KEY, name TEXT, last_message_time TIMESTAMP);
CREATE TABLE messages (
  id TEXT, chat_jid TEXT, sender TEXT, content TEXT, timestamp TIMESTAMP, is_from_me BOOLEAN
);
INSERT INTO chats (jid, name) VALUES ('allowed@g.us', 'Allowed Group');
INSERT INTO chats (jid, name) VALUES ('blocked@g.us', 'Blocked Group');
SQL
}

run_installer() {
  local tmp="$1"
  shift
  (
    cd "$tmp/repo"
    HOME="$tmp/home" \
    PATH="$tmp/fakebin:/usr/bin:/bin" \
    FAKE_CMD_LOG="$tmp/cmd.log" \
    "$@" \
    ./scripts/install-message-notifier-launchd-macos.sh
  )
}

run_uninstaller() {
  local tmp="$1"
  (
    cd "$tmp/repo"
    HOME="$tmp/home" \
    PATH="$tmp/fakebin:/usr/bin:/bin" \
    FAKE_CMD_LOG="$tmp/cmd.log" \
    ./scripts/uninstall-message-notifier-launchd-macos.sh
  )
}

run_checker() {
  local tmp="$1"
  shift
  HOME="$tmp/home" \
  PATH="$tmp/fakebin:/usr/bin:/bin" \
  FAKE_CMD_LOG="$tmp/cmd.log" \
  FAKE_NOTIFY_LOG="$tmp/notify.log" \
  "$@" \
  "$tmp/home/Library/Application Support/whatsapp-mcp/check-new-messages.sh"
}

test_install_generates_launchd_files() {
  local tmp support launch_agents
  tmp="$(make_fixture)"
  run_installer "$tmp" env WHATSAPP_ALLOWED_CHATS="a@g.us,b@s.whatsapp.net"

  support="$tmp/home/Library/Application Support/whatsapp-mcp"
  launch_agents="$tmp/home/Library/LaunchAgents"

  assert_file "$support/notifier.env"
  assert_file "$support/check-new-messages.sh"
  assert_file "$launch_agents/com.whatsapp-mcp.message-notifier.plist"

  assert_contains "$support/notifier.env" "export WHATSAPP_ALLOWED_CHATS='a@g.us,b@s.whatsapp.net'"
  assert_contains "$support/notifier.env" "export WHATSAPP_NOTIFIER_CLAUDE_BIN='$tmp/fakebin/claude'"
  assert_contains "$support/notifier.env" "export WHATSAPP_NOTIFIER_MAX_MESSAGES='50'"
  assert_contains "$support/notifier.env" "export WHATSAPP_NOTIFIER_MODEL='claude-haiku-4-5-20251001'"
  assert_contains "$launch_agents/com.whatsapp-mcp.message-notifier.plist" "<key>StartInterval</key><integer>1800</integer>"
  assert_contains "$tmp/cmd.log" "launchctl bootstrap gui/501"
}

test_install_fails_without_allowed_chats() {
  local tmp launch_agents
  tmp="$(make_fixture)"
  if run_installer "$tmp" env 2>"$tmp/stderr.log"; then
    fail "installer should fail when WHATSAPP_ALLOWED_CHATS is unset"
  fi
  assert_contains "$tmp/stderr.log" "WHATSAPP_ALLOWED_CHATS"
  launch_agents="$tmp/home/Library/LaunchAgents"
  assert_not_exists "$launch_agents/com.whatsapp-mcp.message-notifier.plist"
}

test_install_rejects_interval_below_minimum() {
  local tmp
  tmp="$(make_fixture)"
  if run_installer "$tmp" env WHATSAPP_ALLOWED_CHATS="a@g.us" WHATSAPP_NOTIFIER_INTERVAL_SECONDS="30" 2>"$tmp/stderr.log"; then
    fail "installer should reject an interval below the 60s minimum"
  fi
  assert_contains "$tmp/stderr.log" "WHATSAPP_NOTIFIER_INTERVAL_SECONDS"
}

test_checker_no_new_messages_skips_claude_and_notify() {
  local tmp db
  tmp="$(make_fixture)"
  run_installer "$tmp" env WHATSAPP_ALLOWED_CHATS="allowed@g.us"
  db="$tmp/repo/whatsapp-bridge/store/messages.db"
  seed_db "$db"
  # No message rows at all — nothing to find regardless of the lookback window.

  run_checker "$tmp" env WHATSAPP_DB_PATH="$db"

  assert_not_contains "$tmp/cmd.log" "claude "
  assert_not_exists "$tmp/notify.log"
  assert_file "$tmp/home/Library/Application Support/whatsapp-mcp/state/last-message-check"
}

test_checker_new_allowed_message_triggers_claude_and_notify() {
  local tmp db state_dir
  tmp="$(make_fixture)"
  run_installer "$tmp" env WHATSAPP_ALLOWED_CHATS="allowed@g.us"
  db="$tmp/repo/whatsapp-bridge/store/messages.db"
  seed_db "$db"
  state_dir="$tmp/home/Library/Application Support/whatsapp-mcp/state"
  mkdir -p "$state_dir"
  print -r -- "2020-01-01 00:00:00" > "$state_dir/last-message-check"
  sqlite3 "$db" "INSERT INTO messages VALUES ('m1', 'allowed@g.us', '15551234567', 'anyone free Friday?', '2030-01-01 00:00:00', 0);"

  run_checker "$tmp" env WHATSAPP_DB_PATH="$db" FAKE_CLAUDE_SUMMARY="Someone asked about Friday"

  assert_contains "$tmp/cmd.log" "claude "
  assert_contains "$tmp/cmd.log" "anyone free Friday?"
  assert_contains "$tmp/cmd.log" "--restricted"
  assert_contains "$tmp/cmd.log" "--model claude-haiku-4-5-20251001"
  assert_contains "$tmp/notify.log" "Someone asked about Friday"
  assert_not_contains "$state_dir/last-message-check" "2020-01-01"
}

test_checker_ignores_messages_outside_allowlist() {
  local tmp db
  tmp="$(make_fixture)"
  run_installer "$tmp" env WHATSAPP_ALLOWED_CHATS="allowed@g.us"
  db="$tmp/repo/whatsapp-bridge/store/messages.db"
  seed_db "$db"
  state_dir="$tmp/home/Library/Application Support/whatsapp-mcp/state"
  mkdir -p "$state_dir"
  print -r -- "2020-01-01 00:00:00" > "$state_dir/last-message-check"
  sqlite3 "$db" "INSERT INTO messages VALUES ('m1', 'blocked@g.us', '15551234567', 'not in scope', '2030-01-01 00:00:00', 0);"

  run_checker "$tmp" env WHATSAPP_DB_PATH="$db"

  assert_not_contains "$tmp/cmd.log" "claude "
  assert_not_exists "$tmp/notify.log"
}

test_checker_ignores_own_messages() {
  local tmp db
  tmp="$(make_fixture)"
  run_installer "$tmp" env WHATSAPP_ALLOWED_CHATS="allowed@g.us"
  db="$tmp/repo/whatsapp-bridge/store/messages.db"
  seed_db "$db"
  state_dir="$tmp/home/Library/Application Support/whatsapp-mcp/state"
  mkdir -p "$state_dir"
  print -r -- "2020-01-01 00:00:00" > "$state_dir/last-message-check"
  sqlite3 "$db" "INSERT INTO messages VALUES ('m1', 'allowed@g.us', 'me', 'sent by me', '2030-01-01 00:00:00', 1);"

  run_checker "$tmp" env WHATSAPP_DB_PATH="$db"

  assert_not_contains "$tmp/cmd.log" "claude "
  assert_not_exists "$tmp/notify.log"
}

test_checker_claude_failure_does_not_advance_checkpoint() {
  local tmp db state_dir
  tmp="$(make_fixture)"
  run_installer "$tmp" env WHATSAPP_ALLOWED_CHATS="allowed@g.us"
  db="$tmp/repo/whatsapp-bridge/store/messages.db"
  seed_db "$db"
  state_dir="$tmp/home/Library/Application Support/whatsapp-mcp/state"
  mkdir -p "$state_dir"
  print -r -- "2020-01-01 00:00:00" > "$state_dir/last-message-check"
  sqlite3 "$db" "INSERT INTO messages VALUES ('m1', 'allowed@g.us', '15551234567', 'urgent?', '2030-01-01 00:00:00', 0);"

  run_checker "$tmp" env WHATSAPP_DB_PATH="$db" FAKE_CLAUDE_FAIL="1"

  assert_not_exists "$tmp/notify.log"
  assert_contains "$state_dir/last-message-check" "2020-01-01"
}

test_uninstall_is_surgical_about_shared_state_dir() {
  local tmp state_dir
  tmp="$(make_fixture)"
  run_installer "$tmp" env WHATSAPP_ALLOWED_CHATS="allowed@g.us"
  state_dir="$tmp/home/Library/Application Support/whatsapp-mcp/state"
  mkdir -p "$state_dir"
  print -r -- "now" > "$state_dir/last-message-check"
  # Simulate a marker the bridge monitor owns, sharing the same state dir.
  : > "$state_dir/down.alerted"

  run_uninstaller "$tmp"

  assert_not_exists "$tmp/home/Library/LaunchAgents/com.whatsapp-mcp.message-notifier.plist"
  assert_not_exists "$tmp/home/Library/Application Support/whatsapp-mcp/check-new-messages.sh"
  assert_not_exists "$tmp/home/Library/Application Support/whatsapp-mcp/notifier.env"
  assert_not_exists "$state_dir/last-message-check"
  assert_exists "$state_dir/down.alerted"
}

for test_name in \
  test_install_generates_launchd_files \
  test_install_fails_without_allowed_chats \
  test_install_rejects_interval_below_minimum \
  test_checker_no_new_messages_skips_claude_and_notify \
  test_checker_new_allowed_message_triggers_claude_and_notify \
  test_checker_ignores_messages_outside_allowlist \
  test_checker_ignores_own_messages \
  test_checker_claude_failure_does_not_advance_checkpoint \
  test_uninstall_is_surgical_about_shared_state_dir
do
  print -r -- "Running $test_name"
  "$test_name"
done

if (( failures > 0 )); then
  print -r -- "$failures test failure(s)" >&2
  exit 1
fi

print -r -- "All message-notifier launchd script tests passed"
