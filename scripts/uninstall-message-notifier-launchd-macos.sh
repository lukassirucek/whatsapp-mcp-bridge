#!/bin/zsh
set -euo pipefail

NOTIFIER_LABEL="com.whatsapp-mcp.message-notifier"

fail() {
  print -r -- "Error: $1" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "launchd uninstall is only supported on macOS."
[[ "${EUID:-$(id -u)}" != "0" ]] || fail "Do not run this uninstaller with sudo; it removes a per-user LaunchAgent."

SUPPORT_DIR="$HOME/Library/Application Support/whatsapp-mcp"
LOG_DIR="$HOME/Library/Logs/whatsapp-mcp"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
NOTIFIER_PLIST="$LAUNCH_AGENTS_DIR/$NOTIFIER_LABEL.plist"
LAUNCHD_DOMAIN="gui/$(id -u)"

print -r -- "Stopping message-notifier LaunchAgent if present..."
launchctl bootout "$LAUNCHD_DOMAIN/$NOTIFIER_LABEL" 2>/dev/null || true

rm -f "$NOTIFIER_PLIST"
rm -f "$SUPPORT_DIR/check-new-messages.sh"
rm -f "$SUPPORT_DIR/notifier.env"
# Only this notifier's own checkpoint — SUPPORT_DIR/state is shared with the
# bridge monitor's alert markers when both are installed, so it is not
# removed wholesale here.
rm -f "$SUPPORT_DIR/state/last-message-check"

print -r -- "Removed the message-notifier LaunchAgent and its generated files."
print -r -- "Logs were left in place: $LOG_DIR/message-notifier.out.log / message-notifier.err.log"
