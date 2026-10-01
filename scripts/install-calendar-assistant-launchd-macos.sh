#!/bin/zsh
set -euo pipefail

# Installs a per-user LaunchAgent that periodically checks the local
# messages.db for new inbound WhatsApp messages, grouped into the projects
# defined in your whatsapp-notifier-projects.json config (one calendar per
# project), and — only when something new arrives — runs a local action
# script. See check-new-messages-calendar-assistant.sh.template in this same
# directory for what that action script actually does and what it needs
# (Google Calendar / Gmail / Slack claude.ai connectors). This installer only
# wires up scheduling, config, and paths — it does not contain any of the
# actual prompt/automation logic itself.
#
# Read the template file and whatsapp-notifier-projects.example.json before
# installing, and start with a project or two you're comfortable with it
# acting on without you reviewing first.

ASSISTANT_LABEL="com.whatsapp-mcp.calendar-assistant"

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
CLAUDE_BIN="$(command -v claude || true)"
[[ -n "$CLAUDE_BIN" ]] || fail "claude CLI not found on PATH; install Claude Code first."
command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 not found on PATH."
command -v jq >/dev/null 2>&1 || fail "jq not found on PATH; install it (e.g. 'brew install jq')."
TERMINAL_NOTIFIER_BIN="$(command -v terminal-notifier || true)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BRIDGE_DIR="$REPO_ROOT/whatsapp-bridge"

[[ -d "$BRIDGE_DIR" ]] || fail "Could not find bridge directory: $BRIDGE_DIR"

CONFIG_PATH="${WHATSAPP_NOTIFIER_CONFIG:-$REPO_ROOT/whatsapp-notifier-projects.json}"
[[ -f "$CONFIG_PATH" ]] || fail "Config not found at $CONFIG_PATH. Copy whatsapp-notifier-projects.example.json to that path (or set WHATSAPP_NOTIFIER_CONFIG elsewhere) and fill in your own calendars/chats first."
jq empty "$CONFIG_PATH" 2>/dev/null || fail "Config at $CONFIG_PATH is not valid JSON."
PROJECT_COUNT="$(jq '.projects | length' "$CONFIG_PATH")"
(( PROJECT_COUNT > 0 )) || fail "Config at $CONFIG_PATH has no projects defined."

CHECKER_TEMPLATE="$SCRIPT_DIR/check-new-messages-calendar-assistant.sh.template"
[[ -f "$CHECKER_TEMPLATE" ]] || fail "Missing $CHECKER_TEMPLATE"

DB_PATH="${WHATSAPP_DB_PATH:-$BRIDGE_DIR/store/messages.db}"
INTERVAL_SECONDS="${WHATSAPP_NOTIFIER_INTERVAL_SECONDS:-1800}"
validate_positive_int "WHATSAPP_NOTIFIER_INTERVAL_SECONDS" "$INTERVAL_SECONDS" 60
MAX_MESSAGES="${WHATSAPP_NOTIFIER_MAX_MESSAGES:-50}"
validate_positive_int "WHATSAPP_NOTIFIER_MAX_MESSAGES" "$MAX_MESSAGES" 1
LOOKBACK_MINUTES="${WHATSAPP_NOTIFIER_LOOKBACK_MINUTES:-30}"
validate_positive_int "WHATSAPP_NOTIFIER_LOOKBACK_MINUTES" "$LOOKBACK_MINUTES" 1
MODEL="${WHATSAPP_NOTIFIER_MODEL:-claude-sonnet-5}"

SUPPORT_DIR="$HOME/Library/Application Support/whatsapp-mcp"
STATE_DIR="$SUPPORT_DIR/state"
LOG_DIR="$HOME/Library/Logs/whatsapp-mcp"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
ENV_FILE="$SUPPORT_DIR/calendar-assistant.env"
CHECKER_SCRIPT="$SUPPORT_DIR/check-new-messages-calendar-assistant.sh"
ASSISTANT_PLIST="$LAUNCH_AGENTS_DIR/$ASSISTANT_LABEL.plist"

USER_ID="$(id -u)"
LAUNCHD_DOMAIN="gui/$USER_ID"

mkdir -p "$SUPPORT_DIR" "$STATE_DIR" "$LOG_DIR" "$LAUNCH_AGENTS_DIR"

print -r -- "Stopping existing calendar-assistant LaunchAgent if present..."
bootout_label "$LAUNCHD_DOMAIN" "$ASSISTANT_LABEL"

old_umask="$(umask)"
umask 077
: > "$ENV_FILE"
umask "$old_umask"
write_export "WHATSAPP_NOTIFIER_CONFIG" "$CONFIG_PATH"
write_export "WHATSAPP_DB_PATH" "$DB_PATH"
write_export "WHATSAPP_MCP_STATE_DIR" "$STATE_DIR"
write_export "WHATSAPP_MCP_LOG_DIR" "$LOG_DIR"
write_export "WHATSAPP_NOTIFIER_MAX_MESSAGES" "$MAX_MESSAGES"
write_export "WHATSAPP_NOTIFIER_LOOKBACK_MINUTES" "$LOOKBACK_MINUTES"
write_export "WHATSAPP_NOTIFIER_MODEL" "$MODEL"
write_export "WHATSAPP_NOTIFIER_CLAUDE_BIN" "$CLAUDE_BIN"
write_export "WHATSAPP_NOTIFIER_TERMINAL_NOTIFIER_BIN" "$TERMINAL_NOTIFIER_BIN"
chmod 600 "$ENV_FILE"

# The config is re-read fresh on every run (not baked in here), so editing
# whatsapp-notifier-projects.json later does not require reinstalling.
cp "$CHECKER_TEMPLATE" "$CHECKER_SCRIPT"
chmod 755 "$CHECKER_SCRIPT"

cat > "$ASSISTANT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key><string>$ASSISTANT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
      <string>$(xml_escape "$CHECKER_SCRIPT")</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>$INTERVAL_SECONDS</integer>
    <key>StandardOutPath</key><string>$(xml_escape "$LOG_DIR/calendar-assistant.out.log")</string>
    <key>StandardErrorPath</key><string>$(xml_escape "$LOG_DIR/calendar-assistant.err.log")</string>
  </dict>
</plist>
EOF

print -r -- "Loading calendar-assistant LaunchAgent..."
launchctl bootstrap "$LAUNCHD_DOMAIN" "$ASSISTANT_PLIST"
launchctl enable "$LAUNCHD_DOMAIN/$ASSISTANT_LABEL"
launchctl kickstart -k "$LAUNCHD_DOMAIN/$ASSISTANT_LABEL"

print -r -- "Installed $ASSISTANT_LABEL (checks every ${INTERVAL_SECONDS}s, config: $CONFIG_PATH, $PROJECT_COUNT project(s))."
print -r -- "Logs: $LOG_DIR/calendar-assistant.out.log / calendar-assistant.err.log"
print -r -- "State: $STATE_DIR/last-calendar-assistant-check"