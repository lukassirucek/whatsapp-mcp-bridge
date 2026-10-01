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

assert_contains() {
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
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/whatsapp-mcp-calassist-test.XXXXXX")"
  mkdir -p "$tmp/repo/scripts" "$tmp/repo/whatsapp-bridge/store" "$tmp/home" "$tmp/fakebin"

  cp "$REPO_ROOT/scripts/install-calendar-assistant-launchd-macos.sh" "$tmp/repo/scripts/"
  cp "$REPO_ROOT/scripts/check-new-messages-calendar-assistant.sh.template" "$tmp/repo/scripts/"

  cat > "$tmp/fakebin/uname" <<'EOF'
#!/bin/sh
printf 'Darwin\n'
EOF

  cat > "$tmp/fakebin/id" <<'EOF'
#!/bin/sh
if [ "$1" = "-u" ]; then printf '501\n'; exit 0; fi
/usr/bin/id "$@"
EOF

  cat > "$tmp/fakebin/launchctl" <<'EOF'
#!/bin/sh
printf 'launchctl %s\n' "$*" >> "$FAKE_CMD_LOG"
exit 0
EOF

  # Records every invocation (prompt is the final argument) and prints a
  # canned summary, unless FAKE_CLAUDE_FAIL=1.
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

seed_db() {
  local db_path="$1"
  sqlite3 "$db_path" <<'SQL'
CREATE TABLE chats (jid TEXT PRIMARY KEY, name TEXT, last_message_time TIMESTAMP);
CREATE TABLE messages (
  id TEXT, chat_jid TEXT, sender TEXT, content TEXT, timestamp TIMESTAMP, is_from_me BOOLEAN
);
INSERT INTO chats (jid, name) VALUES ('family-chat@g.us', 'Family Group');
INSERT INTO chats (jid, name) VALUES ('work-chat@g.us', 'Work Group');
INSERT INTO chats (jid, name) VALUES ('unrelated@g.us', 'Unrelated Group');
SQL
}

write_config() {
  # NOTE: never name this local "path" — zsh ties $path to $PATH, and
  # shadowing it here silently breaks every command lookup in this function.
  local config_path="$1"
  local status_email="$2"
  local slack_channel="$3"
  cat > "$config_path" <<JSON
{
  "statusEmailTo": "$status_email",
  "slackChannelId": "$slack_channel",
  "crossPostingNotes": "",
  "projects": [
    {
      "tag": "Family",
      "calendarId": "family@example.com",
      "description": "Household stuff",
      "chats": ["family-chat@g.us"]
    },
    {
      "tag": "Work",
      "calendarId": "work@example.com",
      "description": "Work stuff",
      "chats": ["work-chat@g.us"]
    }
  ]
}
JSON
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
    ./scripts/install-calendar-assistant-launchd-macos.sh
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
  "$tmp/home/Library/Application Support/whatsapp-mcp/check-new-messages-calendar-assistant.sh"
}

test_install_fails_without_config() {
  local tmp
  tmp="$(make_fixture)"
  if run_installer "$tmp" env 2>"$tmp/stderr.log"; then
    fail "installer should fail when no config file exists"
  fi
  assert_contains "$tmp/stderr.log" "whatsapp-notifier-projects"
}

test_install_fails_with_invalid_json() {
  local tmp config
  tmp="$(make_fixture)"
  config="$tmp/repo/whatsapp-notifier-projects.json"
  print -r -- "{ not valid json" > "$config"
  if run_installer "$tmp" env WHATSAPP_NOTIFIER_CONFIG="$config" 2>"$tmp/stderr.log"; then
    fail "installer should fail on invalid JSON"
  fi
  assert_contains "$tmp/stderr.log" "not valid JSON"
}

test_install_fails_with_no_projects() {
  local tmp config
  tmp="$(make_fixture)"
  config="$tmp/repo/whatsapp-notifier-projects.json"
  print -r -- '{"projects": []}' > "$config"
  if run_installer "$tmp" env WHATSAPP_NOTIFIER_CONFIG="$config" 2>"$tmp/stderr.log"; then
    fail "installer should fail when projects is empty"
  fi
  assert_contains "$tmp/stderr.log" "no projects"
}

test_install_generates_launchd_files() {
  local tmp config support launch_agents
  tmp="$(make_fixture)"
  config="$tmp/repo/whatsapp-notifier-projects.json"
  write_config "$config" "status@example.com" "C0123456789"
  run_installer "$tmp" env WHATSAPP_NOTIFIER_CONFIG="$config"

  support="$tmp/home/Library/Application Support/whatsapp-mcp"
  launch_agents="$tmp/home/Library/LaunchAgents"

  assert_file "$support/calendar-assistant.env"
  assert_file "$support/check-new-messages-calendar-assistant.sh"
  assert_file "$launch_agents/com.whatsapp-mcp.calendar-assistant.plist"
  assert_contains "$support/calendar-assistant.env" "export WHATSAPP_NOTIFIER_CONFIG='$config'"
  assert_contains "$launch_agents/com.whatsapp-mcp.calendar-assistant.plist" "<key>StartInterval</key><integer>1800</integer>"
}

test_checker_no_new_messages_skips_claude() {
  local tmp config db
  tmp="$(make_fixture)"
  config="$tmp/repo/whatsapp-notifier-projects.json"
  write_config "$config" "status@example.com" "C0123456789"
  run_installer "$tmp" env WHATSAPP_NOTIFIER_CONFIG="$config"
  db="$tmp/repo/whatsapp-bridge/store/messages.db"
  seed_db "$db"

  run_checker "$tmp" env WHATSAPP_DB_PATH="$db"

  assert_not_contains "$tmp/cmd.log" "claude "
}

test_checker_new_message_includes_project_and_email_tool() {
  local tmp config db state_dir
  tmp="$(make_fixture)"
  config="$tmp/repo/whatsapp-notifier-projects.json"
  write_config "$config" "status@example.com" ""
  run_installer "$tmp" env WHATSAPP_NOTIFIER_CONFIG="$config"
  db="$tmp/repo/whatsapp-bridge/store/messages.db"
  seed_db "$db"
  state_dir="$tmp/home/Library/Application Support/whatsapp-mcp/state"
  mkdir -p "$state_dir"
  print -r -- "2020-01-01 00:00:00" > "$state_dir/last-calendar-assistant-check"
  sqlite3 "$db" "INSERT INTO messages VALUES ('m1', 'family-chat@g.us', '15551234567', 'soccer practice moved to Friday', '2030-01-01 00:00:00', 0);"

  run_checker "$tmp" env WHATSAPP_DB_PATH="$db"

  assert_contains "$tmp/cmd.log" "soccer practice moved to Friday"
  assert_contains "$tmp/cmd.log" "mcp__claude_ai_Gmail__send_message"
  assert_not_contains "$tmp/cmd.log" "mcp__claude_ai_Slack__slack_send_message"
  assert_contains "$tmp/cmd.log" "- Family: Household stuff. Calendar: family@example.com."
}

test_checker_email_and_slack_tools_omitted_when_unconfigured() {
  local tmp config db state_dir
  tmp="$(make_fixture)"
  config="$tmp/repo/whatsapp-notifier-projects.json"
  write_config "$config" "" ""
  run_installer "$tmp" env WHATSAPP_NOTIFIER_CONFIG="$config"
  db="$tmp/repo/whatsapp-bridge/store/messages.db"
  seed_db "$db"
  state_dir="$tmp/home/Library/Application Support/whatsapp-mcp/state"
  mkdir -p "$state_dir"
  print -r -- "2020-01-01 00:00:00" > "$state_dir/last-calendar-assistant-check"
  sqlite3 "$db" "INSERT INTO messages VALUES ('m1', 'family-chat@g.us', '15551234567', 'dentist appointment Tuesday', '2030-01-01 00:00:00', 0);"

  run_checker "$tmp" env WHATSAPP_DB_PATH="$db"

  assert_contains "$tmp/cmd.log" "claude "
  assert_not_contains "$tmp/cmd.log" "mcp__claude_ai_Gmail__send_message"
  assert_not_contains "$tmp/cmd.log" "mcp__claude_ai_Slack__slack_send_message"
}

test_checker_ignores_chat_outside_any_project() {
  local tmp config db state_dir
  tmp="$(make_fixture)"
  config="$tmp/repo/whatsapp-notifier-projects.json"
  write_config "$config" "status@example.com" "C0123456789"
  run_installer "$tmp" env WHATSAPP_NOTIFIER_CONFIG="$config"
  db="$tmp/repo/whatsapp-bridge/store/messages.db"
  seed_db "$db"
  state_dir="$tmp/home/Library/Application Support/whatsapp-mcp/state"
  mkdir -p "$state_dir"
  print -r -- "2020-01-01 00:00:00" > "$state_dir/last-calendar-assistant-check"
  sqlite3 "$db" "INSERT INTO messages VALUES ('m1', 'unrelated@g.us', '15551234567', 'not in any project', '2030-01-01 00:00:00', 0);"

  run_checker "$tmp" env WHATSAPP_DB_PATH="$db"

  assert_not_contains "$tmp/cmd.log" "claude "
}

test_checker_claude_failure_does_not_advance_checkpoint() {
  local tmp config db state_dir
  tmp="$(make_fixture)"
  config="$tmp/repo/whatsapp-notifier-projects.json"
  write_config "$config" "status@example.com" "C0123456789"
  run_installer "$tmp" env WHATSAPP_NOTIFIER_CONFIG="$config"
  db="$tmp/repo/whatsapp-bridge/store/messages.db"
  seed_db "$db"
  state_dir="$tmp/home/Library/Application Support/whatsapp-mcp/state"
  mkdir -p "$state_dir"
  print -r -- "2020-01-01 00:00:00" > "$state_dir/last-calendar-assistant-check"
  sqlite3 "$db" "INSERT INTO messages VALUES ('m1', 'family-chat@g.us', '15551234567', 'urgent thing', '2030-01-01 00:00:00', 0);"

  run_checker "$tmp" env WHATSAPP_DB_PATH="$db" FAKE_CLAUDE_FAIL="1"

  assert_contains "$state_dir/last-calendar-assistant-check" "2020-01-01"
}

for test_name in \
  test_install_fails_without_config \
  test_install_fails_with_invalid_json \
  test_install_fails_with_no_projects \
  test_install_generates_launchd_files \
  test_checker_no_new_messages_skips_claude \
  test_checker_new_message_includes_project_and_email_tool \
  test_checker_email_and_slack_tools_omitted_when_unconfigured \
  test_checker_ignores_chat_outside_any_project \
  test_checker_claude_failure_does_not_advance_checkpoint
do
  print -r -- "Running $test_name"
  "$test_name"
done

if (( failures > 0 )); then
  print -r -- "$failures test failure(s)" >&2
  exit 1
fi

print -r -- "All calendar-assistant launchd script tests passed"
