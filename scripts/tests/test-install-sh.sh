#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

failures=0

fail() {
  print -r -- "FAIL: $1" >&2
  failures=$((failures + 1))
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

# NOTE: never name a local "path" — zsh ties $path to $PATH, and shadowing it
# silently breaks every command lookup in that scope (bit us twice already).
make_fixture() {
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/whatsapp-mcp-install-test.XXXXXX")"
  mkdir -p "$tmp/repo/scripts" "$tmp/repo/whatsapp-mcp-server" "$tmp/home" "$tmp/fakebin"

  cp "$REPO_ROOT/scripts/install.sh" "$tmp/repo/scripts/"
  chmod +x "$tmp/repo/scripts/install.sh"

  cat > "$tmp/fakebin/uname" <<'EOF'
#!/bin/sh
printf 'Darwin\n'
EOF

  cat > "$tmp/fakebin/id" <<'EOF'
#!/bin/sh
if [ "$1" = "-u" ]; then printf '501\n'; exit 0; fi
/usr/bin/id "$@"
EOF

  # go/uv/brew have no real binary on a restricted /usr/bin:/bin PATH, so a
  # dumb stub safely stands in for "present". sqlite3/jq DO have real system
  # binaries (this fixture's PATH falls through to /usr/bin) — a no-op stub
  # for jq specifically would break configure_claude_desktop's real JSON
  # logic (jq -e / jq --arg merge), since every call would just "succeed"
  # without producing real output, so jq/sqlite3 are deliberately left real.
  for tool in go uv brew; do
    cat > "$tmp/fakebin/$tool" <<EOF
#!/bin/sh
printf '$tool %s\n' "\$*" >> "\$FAKE_CMD_LOG"
exit 0
EOF
  done

  chmod +x "$tmp/fakebin/"*
  print -r -- "$tmp"
}

# A fake install-launchd-macos.sh that writes to the real bridge.out.log path
# incrementally (simulating the real bridge pairing/connecting over time),
# so the polling loop in install.sh is actually exercised.
write_fake_bridge_installer() {
  local tmp="$1"
  local log_lines_file="$2"  # file with one log line per line to emit
  cat > "$tmp/repo/scripts/install-launchd-macos.sh" <<EOF
#!/bin/zsh
set -euo pipefail
LOG_DIR="\$HOME/Library/Logs/whatsapp-mcp"
mkdir -p "\$LOG_DIR"
: > "\$LOG_DIR/bridge.out.log"
(
  while IFS= read -r line; do
    print -r -- "\$line" >> "\$LOG_DIR/bridge.out.log"
    sleep 0.2
  done < "$log_lines_file"
) &
EOF
  chmod +x "$tmp/repo/scripts/install-launchd-macos.sh"
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
    ./scripts/install.sh
  )
}

test_fails_cleanly_when_prereqs_missing_and_declined() {
  local tmp
  tmp="$(make_fixture)"
  # go has no real fallback on this fixture's restricted PATH (unlike
  # sqlite3/jq, which fall through to the real /usr/bin ones), so removing
  # its stub is enough to make it genuinely "missing".
  rm -f "$tmp/fakebin/go"

  if print -r -- "n" | run_installer "$tmp" env 2>"$tmp/stderr.log"; then
    fail "installer should fail when the user declines installing missing prerequisites"
  fi
  assert_contains "$tmp/stderr.log" "Install the missing tools"
}

test_streams_qr_and_detects_connection() {
  local tmp log_lines
  tmp="$(make_fixture)"
  log_lines="$tmp/loglines.txt"
  cat > "$log_lines" <<'EOF'
Starting WhatsApp client...
Scan this QR code with your WhatsApp app:
[fake QR art here]
Successfully connected to WhatsApp servers
EOF
  write_fake_bridge_installer "$tmp" "$log_lines"

  print -r -- "n" | run_installer "$tmp" env > "$tmp/stdout.log" 2>&1

  assert_contains "$tmp/stdout.log" "Scan this QR code"
  assert_contains "$tmp/stdout.log" "Bridge connected to WhatsApp."
}

test_claude_config_creates_new_file() {
  local tmp log_lines config
  tmp="$(make_fixture)"
  log_lines="$tmp/loglines.txt"
  print -r -- "Successfully connected to WhatsApp servers" > "$log_lines"
  write_fake_bridge_installer "$tmp" "$log_lines"
  config="$tmp/home/Library/Application Support/Claude/claude_desktop_config.json"

  print -r -- "y" | run_installer "$tmp" env > "$tmp/stdout.log" 2>&1

  assert_contains "$config" '"whatsapp"'
  assert_contains "$config" '"command": "uv"'
}

test_claude_config_preserves_existing_keys() {
  local tmp log_lines config
  tmp="$(make_fixture)"
  log_lines="$tmp/loglines.txt"
  print -r -- "Successfully connected to WhatsApp servers" > "$log_lines"
  write_fake_bridge_installer "$tmp" "$log_lines"
  config="$tmp/home/Library/Application Support/Claude/claude_desktop_config.json"
  mkdir -p "$(dirname "$config")"
  print -r -- '{"mcpServers": {"other": {"command": "foo"}}, "somePref": true}' > "$config"

  print -r -- "y" | run_installer "$tmp" env > "$tmp/stdout.log" 2>&1

  assert_contains "$config" '"other"'
  assert_contains "$config" '"somePref": true'
  assert_contains "$config" '"whatsapp"'
}

test_claude_config_declines_overwrite_of_existing_whatsapp_entry() {
  local tmp log_lines config
  tmp="$(make_fixture)"
  log_lines="$tmp/loglines.txt"
  print -r -- "Successfully connected to WhatsApp servers" > "$log_lines"
  write_fake_bridge_installer "$tmp" "$log_lines"
  config="$tmp/home/Library/Application Support/Claude/claude_desktop_config.json"
  mkdir -p "$(dirname "$config")"
  print -r -- '{"mcpServers": {"whatsapp": {"command": "custom-existing"}}}' > "$config"

  print -r -- "y
n" | run_installer "$tmp" env > "$tmp/stdout.log" 2>&1

  assert_contains "$config" '"custom-existing"'
  assert_not_contains "$config" '"uv"'
}

for test_name in \
  test_fails_cleanly_when_prereqs_missing_and_declined \
  test_streams_qr_and_detects_connection \
  test_claude_config_creates_new_file \
  test_claude_config_preserves_existing_keys \
  test_claude_config_declines_overwrite_of_existing_whatsapp_entry
do
  print -r -- "Running $test_name"
  "$test_name"
done

if (( failures > 0 )); then
  print -r -- "$failures test failure(s)" >&2
  exit 1
fi

print -r -- "All install.sh tests passed"
