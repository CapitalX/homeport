#!/usr/bin/env bash
#
# Enroll a tailnet device: look up its tailnet address and record the scopes it
# may use. There is NO token to copy, paste, or store anywhere -- the device is
# authenticated by Tailscale (WireGuard) before a request ever reaches the
# bridge, and this only records what it is allowed to do once identified.
#
#   ./add-device.sh <device-name> [scopes]
#
# scopes: comma-separated from read,write,message  (default: read,write)
#   read     query/list only
#   write    create/update/delete
#   message  send iMessages -- grant deliberately, it is outward-facing
#
# Revoke with: ./add-device.sh --remove <device-name>
# (or remove the node from your tailnet entirely, which revokes it everywhere.)
#
# Address lookup happens HERE, at enrollment, rather than in the daemon. On a
# host running the Mac App Store / standalone Tailscale.app the CLI is
# GUI-coupled and fails from a launchd agent with "The Tailscale GUI failed to
# start" while still exiting 0 -- a silent failure whose only symptom is a parse
# error downstream. The open-source (brew) tailscaled does not have that
# problem, but resolving once here is still both faster and more robust, since
# tailnet addresses are stable for the life of a node.
set -euo pipefail

# Find the CLI rather than hardcoding one install layout: Tailscale may be
# installed as Tailscale.app or as the open-source brew daemon with no GUI, and
# a hardcoded /Applications path silently breaks every lookup on the latter.
find_tailscale() {
    local c
    for c in "${TAILSCALE:-}" \
             /Applications/Tailscale.app/Contents/MacOS/Tailscale \
             /opt/homebrew/bin/tailscale \
             /usr/local/bin/tailscale \
             "$(command -v tailscale 2>/dev/null || true)"; do
        [[ -n "$c" && -x "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}
TS="$(find_tailscale)" || {
    echo "!! No tailscale CLI found. Set TAILSCALE=/path/to/tailscale." >&2
    exit 1
}

POLICY="$HOME/Library/Application Support/homeport/policy.json"

# The endpoint clients are told to use. Ask Tailscale for this node's MagicDNS
# name instead of guessing from `hostname -s`: the two are frequently different, and
# a wrong name here is copied straight into the client's config.
HOSTNAME_TS="${BRIDGE_HOST:-$("$TS" status --json 2>/dev/null | python3 -c "
import json,sys
try: print((json.load(sys.stdin)['Self'].get('DNSName') or '').rstrip('.'))
except Exception: print('')")}"
if [[ -z "$HOSTNAME_TS" ]]; then
    echo "!! Could not resolve this node's MagicDNS name. Set BRIDGE_HOST=<name>.ts.net." >&2
    exit 1
fi

mkdir -p "$(dirname "$POLICY")"
[[ -f "$POLICY" ]] || echo '{"allowedUsers":[],"nodes":{}}' > "$POLICY"

if [[ "${1:-}" == "--remove" ]]; then
    [[ -n "${2:-}" ]] || { echo "usage: $0 --remove <device-name>" >&2; exit 64; }
    python3 - "$POLICY" "$2" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1]); doc = json.loads(p.read_text())
if doc.get("nodes", {}).pop(sys.argv[2], None) is None:
    sys.exit(f"'{sys.argv[2]}' is not enrolled")
p.write_text(json.dumps(doc, indent=2) + "\n")
print(f"Revoked '{sys.argv[2]}'. It can still reach the tailnet but the bridge will refuse it.")
PY
    launchctl kickstart -k "gui/$(id -u)/dev.homeport.bridge" 2>/dev/null || true
    exit 0
fi

DEVICE="${1:-}"
SCOPES="${2:-read,write}"

if [[ -z "$DEVICE" ]]; then
    echo "usage: $0 <device-name> [read,write,message]" >&2
    echo "       $0 --remove <device-name>" >&2
    echo "" >&2
    echo "Enrolled:" >&2
    python3 -c "
import json,sys
doc=json.load(open('$POLICY'))
for n,e in sorted(doc.get('nodes',{}).items()):
    print('  %-20s %-16s %s' % (n, e.get('address','?'), '+'.join(e.get('scopes',[]))), file=sys.stderr)
print('  allowedUsers: %s' % ', '.join(doc.get('allowedUsers',[])), file=sys.stderr)"
    echo "" >&2
    echo "On the tailnet but NOT enrolled:" >&2
    "$TS" status --json 2>/dev/null | python3 -c "
import json,sys
doc=json.load(open('$POLICY')); enrolled={e.get('address') for e in doc.get('nodes',{}).values()}
d=json.load(sys.stdin)
peers=[d['Self']]+list((d.get('Peer') or {}).values())
for p in peers:
    v4=[i for i in (p.get('TailscaleIPs') or []) if ':' not in i]
    name=(p.get('DNSName') or '').split('.')[0]
    if v4 and v4[0] not in enrolled:
        print('  %-20s %s' % (name or '?', v4[0]), file=sys.stderr)"
    exit 64
fi

# Resolve the device's tailnet address by hostname.
ADDRESS=$("$TS" status --json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
want='$DEVICE'.lower()
for p in [d['Self']]+list((d.get('Peer') or {}).values()):
    if (p.get('DNSName') or '').split('.')[0].lower()==want:
        ips=p.get('TailscaleIPs') or []
        v4=[i for i in ips if ':' not in i]
        print(v4[0] if v4 else (ips[0] if ips else ''))
        break")

if [[ -z "$ADDRESS" ]]; then
    echo "!! '$DEVICE' is not on this tailnet. Run '$0' with no arguments to list nodes." >&2
    exit 1
fi

# The tailnet user that owns this node; requests are rejected unless their
# Tailscale-User-Login is in allowedUsers.
OWNER=$("$TS" status --json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('User',{}).get(str(d['Self'].get('UserID')),{}).get('LoginName',''))")

python3 - "$POLICY" "$DEVICE" "$ADDRESS" "$SCOPES" "$OWNER" <<'PY'
import json, sys, pathlib
policy, device, address, scopes, owner = sys.argv[1:6]
scopes = [s for s in scopes.split(",") if s]
valid = {"read", "write", "message"}
bad = [s for s in scopes if s not in valid]
if bad:
    sys.exit(f"unknown scope(s): {', '.join(bad)} (valid: read, write, message)")

p = pathlib.Path(policy); doc = json.loads(p.read_text())
doc.setdefault("allowedUsers", [])
doc.setdefault("nodes", {})
if owner and owner not in doc["allowedUsers"]:
    doc["allowedUsers"].append(owner)
doc["nodes"][device] = {"address": address, "scopes": scopes}
p.write_text(json.dumps(doc, indent=2) + "\n")
PY

# The daemon caches policy at first use, so a change needs a restart.
launchctl kickstart -k "gui/$(id -u)/dev.homeport.bridge" 2>/dev/null || true

cat <<EOF

Enrolled '$DEVICE' at $ADDRESS with scopes: $SCOPES

Run this ON $DEVICE -- note there is no token, nothing secret to copy:

  claude mcp add --transport http homeport https://$HOSTNAME_TS/mcp

Verify from $DEVICE:

  curl -s -X POST https://$HOSTNAME_TS/mcp \\
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | head -c 120

Being on the tailnet authenticates it; this enrollment is what authorizes it.
EOF
