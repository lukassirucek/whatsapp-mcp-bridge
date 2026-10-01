#!/bin/zsh
set -euo pipefail

ASSISTANT_LABEL="com.whatsapp-mcp.calendar-assistant"

fail() {
  print -r -- "Error: $1" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "launchd uninstall is only supported on macOS."
[[ "${EUID:-$(id -u)}" != "0" ]] || fail "Do not run this uninstaller with sudo; it removes a per-user LaunchAgent."

SUPPORT_DIR="$HOME/Library/Application Support/whatsapp-mcp"
LOG_DIR="$HOME/Library/Logs/whatsapp-mcp"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
ASSISTANT_PLIST="$LAUNCH_AGENTS_DIR/$ASSISTANT_LABEL.plist"
LAUNCHD_DOMAIN="gui/$(id -u)"

print -r -- "Stopping calendar-assistant LaunchAgent if present..."
launchctl bootout "$LAUNCHD_DOMAIN/$ASSISTANT_LABEL" 2>/dev/null || true

rm -f "$ASSISTANT_PLIST"
rm -f "$SUPPORT_DIR/check-new-messages-calendar-assistant.sh"
rm -f "$SUPPORT_DIR/calendar-assistant.env"
# Only this assistant's own checkpoint — SUPPORT_DIR/state is shared with the
# bridge monitor's alert markers and the plain notifier's checkpoint when
# those are also installed, so it is not removed wholesale here.
rm -f "$SUPPORT_DIR/state/last-calendar-assistant-check"

print -r -- "Removed the calendar-assistant LaunchAgent and its generated files."
print -r -- "Your whatsapp-notifier-projects.json config was left in place."
print -r -- "Logs were left in place: $LOG_DIR/calendar-assistant.out.log / calendar-assistant.err.log"
