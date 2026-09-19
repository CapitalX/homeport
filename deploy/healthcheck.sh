#!/usr/bin/env bash
#
# Verify the whole deployment on THIS host, without needing another tailnet
# node. `pipeline/selftest.sh` exercises tools through the HTTPS endpoint and so
# can only run from a peer (tailscale serve stamps no identity on a same-node
# request); this answers the other question: is the service installed correctly
# and will it still be here after a reboot or an OS update?
#
# Run it after: a rebuild, a macOS update, a reboot, or any time the bridge
# looks wrong from a client.
#
#   ./deploy/healthcheck.sh          # check
#   ./deploy/healthcheck.sh -v       # also print what each check saw
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/bin/Homeport.app"
BIN="$APP/Contents/MacOS/Homeport"
PIN="$ROOT/deploy/signing-identity.pin"
AGENT="dev.homeport.bridge"
WATCHER="dev.homeport.voicememo-watch"
PLIST="$HOME/Library/LaunchAgents/$AGENT.plist"
POLICY="$HOME/Library/Application Support/homeport/policy.json"
PORT="${HTTP_PORT:-8765}"
VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1

PASS=0; FAIL=0; WARN=0
ok()   { printf '\033[32m  OK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '\033[31mFAIL\033[0m   %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '\033[33mWARN\033[0m   %s\n' "$1"; WARN=$((WARN+1)); }
note() { [[ $VERBOSE -eq 1 ]] && printf '       %s\n' "$1"; return 0; }

echo
echo "=== the bundle ==="
if [[ -x "$BIN" ]]; then ok "app bundle present"; else
    bad "no app bundle at $APP — run ./build.sh release"
fi

if codesign --verify --strict "$APP" 2>/dev/null; then
    ok "signature verifies"
else
    bad "signature does not verify — rebuild before anything else touches it"
fi

# The single most important invariant on this host. Every privacy grant the app
# holds is matched against this string; if it drifts they all stop matching at
# once, and Full Disk Access cannot be re-prompted, only re-added by hand.
DR="$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^designated => //p')"
note "DR: ${DR:-<none>}"
if [[ -z "$DR" ]]; then
    bad "cannot read the designated requirement"
elif [[ ! -f "$PIN" ]]; then
    warn "no pin at deploy/$(basename "$PIN") — run ./build.sh to record one"
elif [[ "$DR" == "$(cat "$PIN")" ]]; then
    ok "designated requirement matches the pin (TCC grants hold)"
else
    bad "designated requirement DRIFTED — grants are dropped; see deploy/$(basename "$PIN")"
fi

if codesign -d --verbose=4 "$APP" 2>&1 | grep -q '^Signature=adhoc'; then
    bad "ad-hoc signed — every rebuild will drop all privacy grants"
else
    ok "signed with a real identity (survives rebuilds)"
fi

echo
echo "=== will it come back after a reboot ==="
if [[ -f "$PLIST" ]]; then ok "LaunchAgent plist installed"; else
    bad "no $PLIST — run ./deploy/install-bridge.sh"
fi

PROGRAM="$(plutil -extract ProgramArguments.0 raw -o - "$PLIST" 2>/dev/null || true)"
note "plist program: ${PROGRAM:-<none>}"
if [[ "$PROGRAM" == "$BIN" ]]; then
    ok "plist points at this checkout's bundle"
else
    bad "plist points at '$PROGRAM', not '$BIN' — re-run ./deploy/install-bridge.sh"
fi

for k in RunAtLoad KeepAlive; do
    if [[ "$(plutil -extract "$k" raw -o - "$PLIST" 2>/dev/null)" == "true" ]]; then
        ok "$k is set"
    else
        bad "$k is not set — the service will not restart on its own"
    fi
done

# A LaunchAgent lives in the gui/<uid> domain, which only exists once somebody
# logs in. On an unattended machine that makes automatic login the difference
# between "starts at boot" and "starts whenever a human next sits down". The
# agent cannot simply be a LaunchDaemon instead: EventKit, Contacts, Notes and
# Apple Events all require a user session.
if [[ "$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)" != "" ]]; then
    ok "automatic login is on (gui session exists after an unattended reboot)"
else
    warn "automatic login is OFF — after a reboot the bridge stays down until someone logs in"
fi
if fdesetup status 2>/dev/null | grep -q "FileVault is Off"; then
    ok "FileVault off (no pre-login unlock needed)"
else
    warn "FileVault is ON — an unattended reboot stops at the unlock screen; the agent will not start"
fi
if [[ "$(pmset -g custom 2>/dev/null | awk '/^AC Power/,0' | awk '$1=="sleep"{print $2; exit}')" == "0" ]]; then
    ok "system sleep disabled on AC"
else
    warn "system sleep is enabled — the endpoint goes away when the Mac sleeps"
fi

echo
echo "=== is it running now ==="
if launchctl print "gui/$(id -u)/$AGENT" 2>/dev/null | grep -q "state = running"; then
    ok "$AGENT is running"
else
    bad "$AGENT is not running — launchctl bootstrap gui/\$(id -u) $PLIST"
fi

LISTEN="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
note "listeners: ${LISTEN:-<none>}"
if printf '%s' "$LISTEN" | grep -q '\*:'"$PORT"; then
    bad "bound to ALL interfaces — this must be loopback only"
elif printf '%s' "$LISTEN" | grep -q "127.0.0.1:$PORT"; then
    ok "listening on 127.0.0.1:$PORT only"
else
    bad "nothing listening on $PORT"
fi

CODE="$(curl -s -m 15 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/mcp" -d '{}' 2>/dev/null || true)"
if [[ "$CODE" == "401" ]]; then
    ok "loopback request without identity is rejected (fails closed)"
else
    bad "loopback returned $CODE, expected 401"
fi

echo
echo "=== the tailnet path ==="
find_tailscale() {
    local c
    for c in "${TAILSCALE:-}" \
             /Applications/Tailscale.app/Contents/MacOS/Tailscale \
             /opt/homebrew/bin/tailscale /usr/local/bin/tailscale \
             "$(command -v tailscale 2>/dev/null || true)"; do
        [[ -n "$c" && -x "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}
TS="$(find_tailscale || true)"
if [[ -z "$TS" ]]; then
    bad "no tailscale CLI found (set TAILSCALE=/path/to/tailscale)"
else
    ok "tailscale CLI: $TS"
    SERVE="$("$TS" serve status 2>/dev/null || true)"
    note "serve: ${SERVE:-<none>}"
    if printf '%s' "$SERVE" | grep -q "127.0.0.1:$PORT"; then
        ok "tailscale serve proxies to 127.0.0.1:$PORT"
    else
        bad "serve is not proxying to $PORT — tailscale serve --bg --https=443 http://127.0.0.1:$PORT"
    fi
    if printf '%s' "$SERVE" | grep -qi funnel; then
        bad "FUNNEL is on — this publishes your data to the public internet"
    else
        ok "funnel off (tailnet only)"
    fi
fi
# serve config is persisted by tailscaled, so it survives a reboot only if
# tailscaled itself starts at boot as a system daemon.
if launchctl print system/com.tailscale.tailscaled 2>/dev/null | grep -q "state = running"; then
    ok "tailscaled runs as a system LaunchDaemon (starts at boot, before login)"
elif pgrep -qx tailscaled; then
    warn "tailscaled is running but not as a system daemon — check it starts at boot"
else
    bad "tailscaled is not running"
fi

echo
echo "=== policy and grants ==="
if POLICY_SUMMARY="$(python3 -c "
import json,sys
d=json.load(open('$POLICY'))
assert d.get('allowedUsers'), 'no allowedUsers'
assert d.get('nodes'), 'no nodes'
print('%d user(s), %d node(s), %d blocked folder(s), %d allowed recipient(s)' % (
    len(d['allowedUsers']), len(d['nodes']),
    len(d.get('readBlockedNoteFolders',[])), len(d.get('allowedRecipients',[]))))" 2>/dev/null)"; then
    ok "policy.json parses and is populated"
    note "$POLICY_SUMMARY"
else
    bad "policy.json missing or malformed — the bridge fails closed and rejects everything"
fi

# Ask the binary itself. This is the only way to see the live TCC state without
# Full Disk Access on the calling terminal.
PING="$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"bridge_ping","arguments":{}}}' \
  | HOMEPORT_RAW=1 "$BIN" 2>/dev/null \
  | python3 -c "
import json,sys
for line in sys.stdin:
    d=json.loads(line)
    if d.get('id')==2: print(d['result']['content'][0]['text'])" 2>/dev/null || true)"

if [[ -z "$PING" ]]; then
    bad "bridge_ping produced no output — the binary did not start"
else
    note "$PING"
    while IFS='=' read -r cap status; do
        [[ -z "$cap" ]] && continue
        case "$status" in
            ok*|"not probed"*) ok "$cap: $status" ;;
            *)                 bad "$cap: $status" ;;
        esac
    done < <(printf '%s' "$PING" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for k,v in sorted(d['capabilities'].items()): print('%s=%s' % (k,v))" 2>/dev/null)
    VER="$(printf '%s' "$PING" | python3 -c "import json,sys;d=json.load(sys.stdin);print('%s, %d tools' % (d['version'], d['toolCount']))" 2>/dev/null || true)"
    [[ -n "$VER" ]] && ok "server reports $VER"
fi

echo
echo "=== the voice-memo watcher ==="
WPY="$HOME/Library/Application Support/homeport/voicememo-watch.py"
if [[ -f "$WPY" ]]; then ok "watcher script installed"; else
    warn "no watcher at $WPY — run ./pipeline/install.sh (optional component)"
fi
if launchctl print "gui/$(id -u)/$WATCHER" >/dev/null 2>&1; then
    ok "$WATCHER is loaded"
    WINT="$(plutil -extract ProgramArguments.0 raw -o - "$HOME/Library/LaunchAgents/$WATCHER.plist" 2>/dev/null || true)"
    note "watcher interpreter: ${WINT:-<none>}"
    # Existence is not enough: /usr/bin/python3 is the Command Line Tools shim
    # and, with the CLT gone, it exits non-zero while trying to raise a GUI
    # installer prompt that nobody under launchd will ever see.
    if [[ -x "$WINT" ]] && "$WINT" -c 'import sys, json, urllib.request' >/dev/null 2>&1; then
        ok "watcher interpreter runs ($WINT)"
    elif [[ -x "$WINT" ]]; then
        bad "watcher interpreter '$WINT' exists but cannot run — re-run ./pipeline/install.sh"
    else
        bad "watcher interpreter '$WINT' is missing — the job fails silently at every firing"
    fi
else
    warn "$WATCHER not loaded (optional component)"
fi

echo
printf 'passed %d   failed %d   warnings %d\n' "$PASS" "$FAIL" "$WARN"
[[ $FAIL -eq 0 ]] || exit 1
