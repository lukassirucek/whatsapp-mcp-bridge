#!/bin/zsh
set -euo pipefail

# One-command setup for the whole WhatsApp MCP service on macOS:
#   1. checks/installs prerequisites (go, uv, sqlite3, jq)
#   2. builds the Go bridge and installs it as a background LaunchAgent
#      (scripts/install-launchd-macos.sh)
#   3. waits for it to start, streaming its log inline — so the QR code (or
#      "already paired" confirmation) appears as part of this one command
#      instead of requiring a separate "go check the log" step
#   4. optionally wires up Claude Desktop's MCP server config
#
# This only sets up the core bridge + MCP server. The optional notification
# and calendar-assistant add-ons (scripts/install-message-notifier-launchd-macos.sh,
# scripts/install-calendar-assistant-launchd-macos.sh) are separate and need
# their own configuration — see the README.

fail() {
  print -r -- "Error: $1" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "This installer is only supported on macOS. See the README for manual setup on other platforms."
[[ "${EUID:-$(id -u)}" != "0" ]] || fail "Do not run this installer with sudo."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MCP_SERVER_DIR="$REPO_ROOT/whatsapp-mcp-server"
CLAUDE_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
LOG_DIR="$HOME/Library/Logs/whatsapp-mcp"
BRIDGE_LOG="$LOG_DIR/bridge.out.log"

print_manual_snippet() {
  cat <<SNIPPET
{
  "mcpServers": {
    "whatsapp": {
      "command": "uv",
      "args": ["--directory", "$MCP_SERVER_DIR", "run", "main.py"]
    }
  }
}
SNIPPET
}

configure_claude_desktop() {
  if ! command -v jq >/dev/null 2>&1; then
    print -r -- "jq not found, so I can't safely edit your existing config automatically."
    print -r -- "Add this to $CLAUDE_CONFIG yourself:"
    print_manual_snippet
    return
  fi

  mkdir -p "$(dirname "$CLAUDE_CONFIG")"
  if [[ ! -f "$CLAUDE_CONFIG" ]]; then
    print -r -- '{"mcpServers": {}}' > "$CLAUDE_CONFIG"
  fi
  if ! jq empty "$CLAUDE_CONFIG" 2>/dev/null; then
    print -r -- "$CLAUDE_CONFIG exists but isn't valid JSON — leaving it alone. Add this manually:"
    print_manual_snippet
    return
  fi

  if jq -e '.mcpServers.whatsapp' "$CLAUDE_CONFIG" >/dev/null 2>&1; then
    printf 'A "whatsapp" entry already exists in %s. Overwrite it? [y/N] ' "$CLAUDE_CONFIG"
    read -r overwrite_reply
    if [[ "$overwrite_reply" != "y" && "$overwrite_reply" != "Y" ]]; then
      print -r -- "Left your existing entry unchanged."
      return
    fi
  fi

  local backup="$CLAUDE_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CLAUDE_CONFIG" "$backup"

  local tmp
  tmp="$(mktemp)"
  if jq --arg dir "$MCP_SERVER_DIR" \
      '.mcpServers.whatsapp = {command: "uv", args: ["--directory", $dir, "run", "main.py"]}' \
      "$CLAUDE_CONFIG" > "$tmp"; then
    mv "$tmp" "$CLAUDE_CONFIG"
    print -r -- "Added the whatsapp MCP server to $CLAUDE_CONFIG"
    print -r -- "(backup saved at $backup)"
  else
    rm -f "$tmp"
    print -r -- "Failed to update $CLAUDE_CONFIG automatically. Add this manually:"
    print_manual_snippet
  fi
}

print -r -- "== WhatsApp MCP setup =="
print -r -- ""

# --- 1. Prerequisites -------------------------------------------------------
missing=()
command -v go >/dev/null 2>&1 || missing+=("go")
command -v uv >/dev/null 2>&1 || missing+=("uv")
command -v sqlite3 >/dev/null 2>&1 || missing+=("sqlite3")
command -v jq >/dev/null 2>&1 || missing+=("jq")

if (( ${#missing[@]} > 0 )); then
  print -r -- "Missing: ${missing[*]}"
  if command -v brew >/dev/null 2>&1; then
    printf "Install with Homebrew now? [y/N] "
    read -r install_reply
    if [[ "$install_reply" == "y" || "$install_reply" == "Y" ]]; then
      for tool in "${missing[@]}"; do
        brew install "$tool"
      done
    else
      fail "Install the missing tools, then re-run this script."
    fi
  else
    fail "Homebrew not found. Install the missing tools manually, then re-run this script."
  fi
fi
print -r -- "Prerequisites OK."

# --- 2. Build + start the bridge as a background service --------------------
print -r -- ""
print -r -- "Setting up the WhatsApp bridge..."
zsh "$SCRIPT_DIR/install-launchd-macos.sh"

# --- 3. Wait for pairing, streaming the bridge log (QR code included) -------
print -r -- ""
print -r -- "Waiting for the bridge to connect to WhatsApp..."
print -r -- "If a QR code appears below, scan it with your phone: WhatsApp > Settings > Linked Devices > Link a Device."
print -r -- "(Already paired before? It reconnects on its own, no QR needed.)"
print -r -- ""

seen_lines=0
start_ts=$(date +%s)
timeout_seconds=180
connected=0
while (( $(date +%s) - start_ts < timeout_seconds )); do
  if [[ -f "$BRIDGE_LOG" ]]; then
    total_lines="$(wc -l < "$BRIDGE_LOG" 2>/dev/null | tr -d ' ')"
    total_lines="${total_lines:-0}"
    if (( total_lines > seen_lines )); then
      new_content="$(tail -n "+$((seen_lines + 1))" "$BRIDGE_LOG")"
      if [[ -n "$new_content" ]]; then
        print -r -- "$new_content"
        if print -r -- "$new_content" | grep -q "Successfully connected to WhatsApp servers"; then
          connected=1
        fi
      fi
      seen_lines="$total_lines"
    fi
  fi
  if (( connected )); then
    break
  fi
  sleep 1
done

print -r -- ""
if (( connected )); then
  print -r -- "Bridge connected to WhatsApp."
else
  print -r -- "Still waiting after ${timeout_seconds}s. Check $BRIDGE_LOG for status — the bridge keeps running and retrying in the background, so scanning a QR code whenever one next appears there still works. Re-running this script is also safe."
fi

# --- 4. Configure Claude Desktop ---------------------------------------------
print -r -- ""
print -r -- "== Claude Desktop =="
printf "Add the WhatsApp MCP server to Claude Desktop's config now? [Y/n] "
read -r config_reply
if [[ -z "$config_reply" || "$config_reply" == "y" || "$config_reply" == "Y" ]]; then
  configure_claude_desktop
else
  print -r -- "Skipped. Add this to $CLAUDE_CONFIG yourself:"
  print_manual_snippet
fi

# --- 5. Summary ---------------------------------------------------------------
print -r -- ""
print -r -- "== Done =="
print -r -- "- Bridge: running as a background service, auto-restarts on crash/reboot."
print -r -- "- Next: restart Claude Desktop to pick up the MCP server (if configured above)."
print -r -- "- By default the assistant can read and send in EVERY chat. To scope it down to"
print -r -- "  specific chats, see 'Restricting the assistant to specific chats' in the README."
print -r -- "- Optional add-ons (not installed by this script, need their own setup):"
print -r -- "    scripts/install-message-notifier-launchd-macos.sh    (local notification on new messages)"
print -r -- "    scripts/install-calendar-assistant-launchd-macos.sh  (calendar/email/Slack automation)"
