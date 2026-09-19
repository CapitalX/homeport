#!/usr/bin/env bash
#
# Installs the voice-memo watcher as a LaunchAgent.
#
# The script is COPIED to ~/Library/Application Support/homeport/ rather
# than run from this project directory. If the checkout lives under a
# TCC-protected folder such as ~/Desktop or ~/Documents, launchd-spawned
# processes cannot READ files there -- the job dies with "Operation not
# permitted" before it starts. Executing the signed bridge binary from such a
# folder is still fine; only the script has to move.
set -euo pipefail
cd "$(dirname "$0")"

SUPPORT="$HOME/Library/Application Support/homeport"
AGENT="$HOME/Library/LaunchAgents/dev.homeport.voicememo-watch.plist"
LABEL="dev.homeport.voicememo-watch"
BRIDGE_DIR="$(cd .. && pwd)"
RECORDINGS="$HOME/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"

# Resolve the interpreter now, and prove it RUNS -- do not just assume
# /usr/bin/python3 exists. That path is the Command Line Tools shim: when the
# CLT are absent (which a major macOS update can leave them), it exits non-zero
# and tries to raise a GUI installer prompt. Under launchd nobody sees that
# prompt, so the watcher fails at every firing and the only symptom is voice
# memos quietly never being filed.
find_python() {
    local c
    for c in "${PYTHON:-}" /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
        [[ -n "$c" && -x "$c" ]] && "$c" -c 'import sys, json, urllib.request' >/dev/null 2>&1 \
            && { printf '%s' "$c"; return 0; }
    done
    return 1
}
PYTHON="$(find_python)" || {
    echo "!! No working python3 found. Install the Command Line Tools (xcode-select --install)" >&2
    echo "   or set PYTHON=/path/to/python3." >&2
    exit 1
}
echo "==> Interpreter: $PYTHON"

mkdir -p "$SUPPORT"
cp -f voicememo-watch.py "$SUPPORT/voicememo-watch.py"
chmod +x "$SUPPORT/voicememo-watch.py"
echo "==> Installed watcher to $SUPPORT/voicememo-watch.py"

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOMEPORT_BIN</key>
        <string>$BRIDGE_DIR/bin/Homeport.app/Contents/MacOS/Homeport</string>
    </dict>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON</string>
        <string>$SUPPORT/voicememo-watch.py</string>
    </array>
    <!-- Detection works by asking the bridge for a listing, so the poll needs no
         filesystem access of its own. launchd skips a firing while the previous
         run is still going, so a long summarization cannot pile up. -->
    <key>StartInterval</key><integer>600</integer>
    <!-- Lower latency when it fires; watching a TCC-protected directory is not
         guaranteed, so this supplements the interval rather than replacing it. -->
    <key>WatchPaths</key><array><string>$RECORDINGS</string></array>
    <key>RunAtLoad</key><false/>
    <key>Nice</key><integer>10</integer>
    <key>LowPriorityIO</key><true/>
    <key>ProcessType</key><string>Background</string>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/voicememo-watch.out.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/voicememo-watch.err.log</string>
</dict>
</plist>
PLIST
plutil -lint "$AGENT" >/dev/null
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "==> LaunchAgent loaded ($LABEL), polling every 10 minutes"
echo
echo "First time only -- adopt the newest 50 existing recordings so they are not reprocessed:"
echo "    $PYTHON \"$SUPPORT/voicememo-watch.py\" --seed"
echo "Logs: ~/Library/Logs/voicememo-watch.log"
