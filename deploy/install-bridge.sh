#!/bin/bash
# Install (or re-install) the bridge LaunchAgent on THIS Mac.
#
# Generates the LaunchAgent from the current checkout, so the service can be
# reproduced on any host. This script is the other half of build.sh: build.sh produces the signed .app, this points launchd at
# it with the right environment.
#
# Usage:
#   ./deploy/install-bridge.sh                       # model runs on this Mac
#   LLM_URL=http://other-host:1234/v1/chat/completions ./deploy/install-bridge.sh
#
# Safe to re-run; it replaces the agent in place.
set -euo pipefail

LABEL="dev.homeport.bridge"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXEC="$REPO/bin/Homeport.app/Contents/MacOS/Homeport"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PORT="${HTTP_PORT:-8765}"

[[ -x "$EXEC" ]] || { echo "No built app at $EXEC — run ./build.sh first." >&2; exit 1; }

# LLM_URL is written only when set. Unset means "the model is on this Mac",
# which is LocalLLM.swift's default.
# Find the model server rather than assuming loopback.
#
# LocalLLM defaults to localhost:1234, but some setups bind the model server to
# the TAILNET address only -- where that default is refused and every
# summarize/route call fails with a connection error. Probe for it and write
# whatever actually answers into the agent's environment.
if [[ -z "${LLM_URL:-}" ]]; then
    for host in 127.0.0.1 "$(/opt/homebrew/bin/tailscale ip -4 2>/dev/null | head -1)"; do
        [[ -n "$host" ]] || continue
        if curl -s -m 3 "http://$host:1234/v1/models" >/dev/null 2>&1; then
            LLM_URL="http://$host:1234/v1/chat/completions"
            echo "==> Found the local model at $host:1234"
            break
        fi
    done
fi
LLM_ENTRY=""
if [[ -n "${LLM_URL:-}" ]]; then
    LLM_ENTRY="        <key>HOMEPORT_LLM_URL</key><string>${LLM_URL}</string>"
else
    echo "!! No local model found on :1234 — summarization and auto-routing will fail." >&2
fi

# Live inbox routing. Off unless asked for: a background process that moves a
# person's reminders without being told to is not a default.
ROUTE_ENTRY=""
if [[ -n "${AUTO_ROUTE:-}" ]]; then
    ROUTE_ENTRY="        <key>HOMEPORT_AUTO_ROUTE</key><string>1</string>"
    echo "==> Auto-routing ENABLED (watching Inbox)"
fi

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LABEL}</string>

    <!-- Executed from inside the .app bundle so TCC resolves the grants by
         CFBundleIdentifier. launchd agents cannot READ files under TCC-protected
         folders such as ~/Desktop, but they can EXECUTE one there. -->
    <key>ProgramArguments</key>
    <array>
        <string>${EXEC}</string>
    </array>

    <!-- Presence of the port variable is what selects the HTTP transport over
         stdio. It survives the disclaim re-exec because Disclaim propagates the
         environment explicitly. -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOMEPORT_HTTP_PORT</key><string>${PORT}</string>
${LLM_ENTRY}
${ROUTE_ENTRY}
    </dict>

    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <!-- Adaptive, not Background. ProcessType Background subjects the job to
         CPU and I/O throttling, which is the wrong trade for a service whose
         slowest operation is driving another app over Apple Events. -->
    <key>ProcessType</key><string>Adaptive</string>
    <key>StandardOutPath</key><string>${HOME}/Library/Logs/homeport.out.log</string>
    <key>StandardErrorPath</key><string>${HOME}/Library/Logs/homeport.err.log</string>
</dict>
</plist>
PLIST_EOF

plutil -lint "$PLIST" >/dev/null || { echo "generated plist is malformed" >&2; exit 1; }

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Installed $LABEL"
echo "  exec: $EXEC"
echo "  port: $PORT"
echo "  llm:  ${LLM_URL:-NONE FOUND}"
echo "  auto: $([[ -n "${AUTO_ROUTE:-}" ]] && echo enabled || echo disabled)"
echo
echo "Expose it on the tailnet with:"
echo "  tailscale serve --bg --https=443 http://127.0.0.1:$PORT"
