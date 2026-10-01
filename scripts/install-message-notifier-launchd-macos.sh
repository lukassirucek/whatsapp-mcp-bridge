#!/bin/zsh
set -euo pipefail

# Installs a per-user LaunchAgent that periodically checks the local
# messages.db for new inbound messages in WHATSAPP_ALLOWED_CHATS, and — only
# when something new arrives — asks Claude Code (headless, local) to write a
# short summary and pushes it as a native macOS notification.
#
# This does NOT touch WhatsApp's send capability and does not run any MCP
# server: it reads messages.db directly (read-only) and the only side effect
# of the `claude` invocation itself is text output, captured by this script.
# Delivery uses the same terminal-notifier/osascript fallback as the existing
# bridge monitor, not the PushNotification tool, since a LaunchAgent has no
# interactive terminal/session for that tool to attach to.
#
# For a more capable (and more invasive) option that checks a calendar,
# creates missing events, and sends email/Slack updates, see
# install-calendar-assistant-launchd-macos.sh instead — a separate, optional
# installer you configure per-household via whatsapp-notifier-projects.json.

NOTIFIER_LABEL="com.whatsapp-mcp.message-notifier"

fail() {
  print -r -- "Error: $1" >&2
  exit 1
}

require_macos_user() {
  [[ "$(uname -s)" == "Darwin" ]] || fail "launchd installation is only supported on macOS."
  [[ "${EUID:-$(id -u)}" != "0" ]] || fail "Do not run this installer with sudo; it installs a per-user LaunchAgent."
}

shell_quote() {
  local value="$1"
  printf "'"
  printf "%s" "$value" | sed "s/'/'\\\\''/g"
  printf "'"
}

xml_escape() {
  printf "%s" "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

write_export() {
  local name="$1"
  local value="$2"
  printf "export %s=%s\n" "$name" "$(shell_quote "$value")" >> "$ENV_FILE"
}

validate_positive_int() {
  local name="$1"
  local value="$2"
  local min="$3"
  [[ "$value" =~ '^[0-9]+$' ]] || fail "$name must be a whole number, got: $value"
  (( value >= min )) || fail "$name must be at least $min, got: $value"
}

bootout_label() {
  local domain="$1"
  local label="$2"
  launchctl bootout "$domain/$label" 2>/dev/null || true
}

require_macos_user
# Resolved to an absolute path and baked into the env file: launchd runs
# LaunchAgents with a minimal PATH (typically just /usr/bin:/bin), which does
# not include wherever claude was installed (e.g. ~/.local/bin, Homebrew).
CLAUDE_BIN="$(command -v claude || true)"
[[ -n "$CLAUDE_BIN" ]] || fail "claude CLI not found on PATH; install Claude Code first."
command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 not found on PATH."
# Optional: preferred over osascript when present (more reliable delivery from
# a non-interactive launchd context — see notify() below). Resolved now for
# the same PATH reason as CLAUDE_BIN. Absent is fine; falls back to osascript.
TERMINAL_NOTIFIER_BIN="$(command -v terminal-notifier || true)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BRIDGE_DIR="$REPO_ROOT/whatsapp-bridge"

[[ -d "$BRIDGE_DIR" ]] || fail "Could not find bridge directory: $BRIDGE_DIR"

ALLOWED_CHATS="${WHATSAPP_ALLOWED_CHATS:-}"
[[ -n "$ALLOWED_CHATS" ]] || fail "WHATSAPP_ALLOWED_CHATS must be set to a comma-separated list of chat JIDs (see README: Restricting the assistant to specific chats). Refusing to install a notifier with no scope."

DB_PATH="${WHATSAPP_DB_PATH:-$BRIDGE_DIR/store/messages.db}"
INTERVAL_SECONDS="${WHATSAPP_NOTIFIER_INTERVAL_SECONDS:-1800}"
validate_positive_int "WHATSAPP_NOTIFIER_INTERVAL_SECONDS" "$INTERVAL_SECONDS" 60
MAX_MESSAGES="${WHATSAPP_NOTIFIER_MAX_MESSAGES:-50}"
validate_positive_int "WHATSAPP_NOTIFIER_MAX_MESSAGES" "$MAX_MESSAGES" 1
LOOKBACK_MINUTES="${WHATSAPP_NOTIFIER_LOOKBACK_MINUTES:-30}"
validate_positive_int "WHATSAPP_NOTIFIER_LOOKBACK_MINUTES" "$LOOKBACK_MINUTES" 1
MODEL="${WHATSAPP_NOTIFIER_MODEL:-claude-haiku-4-5-20251001}"

SUPPORT_DIR="$HOME/Library/Application Support/whatsapp-mcp"
STATE_DIR="$SUPPORT_DIR/state"
LOG_DIR="$HOME/Library/Logs/whatsapp-mcp"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
ENV_FILE="$SUPPORT_DIR/notifier.env"
CHECKER_SCRIPT="$SUPPORT_DIR/check-new-messages.sh"
NOTIFIER_PLIST="$LAUNCH_AGENTS_DIR/$NOTIFIER_LABEL.plist"

USER_ID="$(id -u)"
LAUNCHD_DOMAIN="gui/$USER_ID"

mkdir -p "$SUPPORT_DIR" "$STATE_DIR" "$LOG_DIR" "$LAUNCH_AGENTS_DIR"

print -r -- "Stopping existing message-notifier LaunchAgent if present..."
bootout_label "$LAUNCHD_DOMAIN" "$NOTIFIER_LABEL"

old_umask="$(umask)"
umask 077
: > "$ENV_FILE"
umask "$old_umask"
write_export "WHATSAPP_ALLOWED_CHATS" "$ALLOWED_CHATS"
write_export "WHATSAPP_DB_PATH" "$DB_PATH"
write_export "WHATSAPP_MCP_STATE_DIR" "$STATE_DIR"
write_export "WHATSAPP_MCP_LOG_DIR" "$LOG_DIR"
write_export "WHATSAPP_NOTIFIER_MAX_MESSAGES" "$MAX_MESSAGES"
write_export "WHATSAPP_NOTIFIER_LOOKBACK_MINUTES" "$LOOKBACK_MINUTES"
write_export "WHATSAPP_NOTIFIER_MODEL" "$MODEL"
write_export "WHATSAPP_NOTIFIER_CLAUDE_BIN" "$CLAUDE_BIN"
write_export "WHATSAPP_NOTIFIER_TERMINAL_NOTIFIER_BIN" "$TERMINAL_NOTIFIER_BIN"
chmod 600 "$ENV_FILE"

cat > "$CHECKER_SCRIPT" <<EOF
#!/bin/zsh
set -euo pipefail

source $(shell_quote "$ENV_FILE")

STATE_DIR="\${WHATSAPP_MCP_STATE_DIR:-\$HOME/Library/Application Support/whatsapp-mcp/state}"
LOG_DIR="\${WHATSAPP_MCP_LOG_DIR:-\$HOME/Library/Logs/whatsapp-mcp}"
STATE_FILE="\$STATE_DIR/last-message-check"
ERR_LOG="\$LOG_DIR/message-notifier.err.log"

mkdir -p "\$STATE_DIR"

notify() {
  local title="\$1"
  local msg="\$2"
  # Failures are logged, not swallowed: both tools return 0 even when macOS
  # silently drops the notification for a permissions reason (e.g. Do Not
  # Disturb, or Notifications disabled for terminal-notifier), so stderr is
  # the only place a delivery problem like that surfaces.
  if [[ -n "\$WHATSAPP_NOTIFIER_TERMINAL_NOTIFIER_BIN" ]]; then
    "\$WHATSAPP_NOTIFIER_TERMINAL_NOTIFIER_BIN" -title "\$title" -message "\$msg" >>"\$ERR_LOG" 2>&1 || true
  else
    osascript \\
      -e 'on run argv' \\
      -e 'display notification (item 2 of argv) with title (item 1 of argv)' \\
      -e 'end run' \\
      "\$title" "\$msg" >>"\$ERR_LOG" 2>&1 || true
  fi
}

# First run: only look back a short window so pairing/backfill history isn't
# dumped into one giant "new messages" digest.
if [[ ! -f "\$STATE_FILE" ]]; then
  date -u -v-\${WHATSAPP_NOTIFIER_LOOKBACK_MINUTES}M +"%Y-%m-%d %H:%M:%S" > "\$STATE_FILE"
fi
LAST_CHECK="\$(cat "\$STATE_FILE")"
NOW="\$(date -u +"%Y-%m-%d %H:%M:%S")"

# Build a SQL IN (...) list from the comma-separated allowlist. JIDs are
# ASCII (digits, letters, @, ., -) but single quotes are escaped defensively.
JID_LIST=""
IFS=',' read -rA JIDS <<< "\$WHATSAPP_ALLOWED_CHATS"
for jid in "\${JIDS[@]}"; do
  jid="\${jid//[[:space:]]/}"
  [[ -n "\$jid" ]] || continue
  jid="\${jid//\\'/\\'\\'}"
  if [[ -n "\$JID_LIST" ]]; then JID_LIST="\$JID_LIST,"; fi
  JID_LIST="\$JID_LIST'\$jid'"
done

if [[ -z "\$JID_LIST" ]]; then
  print -r -- "WHATSAPP_ALLOWED_CHATS is empty; nothing to check." >> "\$ERR_LOG"
  exit 0
fi

DIGEST="\$(sqlite3 -separator '|' "\$WHATSAPP_DB_PATH" "
  SELECT messages.timestamp, chats.name, messages.sender, messages.content
  FROM messages
  JOIN chats ON messages.chat_jid = chats.jid
  WHERE messages.chat_jid IN (\$JID_LIST)
    AND messages.is_from_me = 0
    AND messages.timestamp > '\$LAST_CHECK'
    AND messages.content != ''
  ORDER BY messages.timestamp ASC
  LIMIT \${WHATSAPP_NOTIFIER_MAX_MESSAGES};
" 2>>"\$ERR_LOG")" || DIGEST=""

if [[ -z "\$DIGEST" ]]; then
  print -r -- "\$NOW" > "\$STATE_FILE"
  exit 0
fi

PROMPT="New inbound WhatsApp messages since the last check (one per line, format: timestamp|chat name|sender|content):

\$DIGEST

Write ONE short push notification summarizing what is new, under 200 characters, one line, no markdown, no preamble, no quotes around it. If several chats have news, lead with whichever most likely needs a response (a question, a request, a deadline) over routine chatter. Output ONLY the notification text."

SUMMARY="\$("\$WHATSAPP_NOTIFIER_CLAUDE_BIN" -p --restricted --permission-prompts none --output-format text --no-session-persistence --model "\$WHATSAPP_NOTIFIER_MODEL" "\$PROMPT" 2>>"\$ERR_LOG")" || SUMMARY=""

if [[ -z "\$SUMMARY" ]]; then
  print -r -- "\$(date -u +"%Y-%m-%d %H:%M:%S") claude invocation failed or returned nothing; will retry with the same messages next run." >> "\$ERR_LOG"
  exit 0
fi

notify "New WhatsApp activity" "\$SUMMARY"
print -r -- "\$NOW" > "\$STATE_FILE"
EOF
chmod 755 "$CHECKER_SCRIPT"

cat > "$NOTIFIER_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key><string>$NOTIFIER_LABEL</string>
    <key>ProgramArguments</key>
    <array>
      <string>$(xml_escape "$CHECKER_SCRIPT")</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>$INTERVAL_SECONDS</integer>
    <key>StandardOutPath</key><string>$(xml_escape "$LOG_DIR/message-notifier.out.log")</string>
    <key>StandardErrorPath</key><string>$(xml_escape "$LOG_DIR/message-notifier.err.log")</string>
  </dict>
</plist>
EOF

print -r -- "Loading message-notifier LaunchAgent..."
launchctl bootstrap "$LAUNCHD_DOMAIN" "$NOTIFIER_PLIST"
launchctl enable "$LAUNCHD_DOMAIN/$NOTIFIER_LABEL"
launchctl kickstart -k "$LAUNCHD_DOMAIN/$NOTIFIER_LABEL"

print -r -- "Installed $NOTIFIER_LABEL (checks every ${INTERVAL_SECONDS}s)."
print -r -- "Logs: $LOG_DIR/message-notifier.out.log / message-notifier.err.log"
print -r -- "State: $STATE_DIR/last-message-check"
