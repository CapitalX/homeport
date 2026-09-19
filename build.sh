#!/usr/bin/env bash
#
# Build (and sign) the Apple MCP Bridge single binary.
#
# The binary embeds its own Info.plist into the __TEXT,__info_plist Mach-O
# section via a linker flag, so EventKit/Contacts permission prompts carry the
# right usage strings and the TCC grant attaches to THIS binary's identity.
#
# Signing:
#   - Set CODESIGN_IDENTITY to a "Developer ID Application: ..." (or Apple
#     Development) identity for a STABLE TCC identity that survives rebuilds.
#   - Otherwise the "Apple MCP Bridge" self-signed identity is used if one is
#     installed (deploy/install-signing-identity.sh), and only failing that do we
#     ad-hoc sign (-). Ad-hoc changes the code hash on every rebuild, so macOS
#     may ask you to re-grant Calendar/Reminders/Contacts access after each one.
#
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
CONFIG="${1:-release}"
PLIST="$ROOT/Sources/Homeport/Resources/Info.plist"
ENTITLEMENTS="$ROOT/Sources/Homeport/Resources/Homeport.entitlements"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" \
    -Xlinker -sectcreate \
    -Xlinker __TEXT \
    -Xlinker __info_plist \
    -Xlinker "$PLIST"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
BINARY="$BIN_PATH/Homeport"

if [[ ! -x "$BINARY" ]]; then
    echo "!! Build did not produce $BINARY" >&2
    exit 1
fi

# Assemble a real .app bundle.
#
# This is not cosmetic. A bare Mach-O is recorded by TCC with client_type=1 --
# keyed by ABSOLUTE PATH -- which means `tccutil` cannot target it ("No such
# bundle identifier", OSStatus -10814), the only way to clear a stale grant is a
# service-wide reset that hits every other app on the system, and moving the
# project directory silently breaks every permission at once. Inside a bundle
# the same code is keyed by CFBundleIdentifier instead, so grants are precisely
# resettable and survive a move.
#
# CFBundleExecutable in Info.plist is "Homeport", so the file in
# Contents/MacOS must carry exactly that name or launchd/TCC won't resolve it.
APP="$ROOT/bin/Homeport.app"
# Built and signed HERE, then swapped into place at the end. The old order
# (bootout -> rm -rf "$APP" -> sign) meant any signing failure left the machine
# with the service stopped and no bundle at all, and `set -e` made that the
# common case rather than the rare one -- KeepAlive cannot restart a binary that
# does not exist. Staging shrinks the outage to one `mv` and makes every failure
# before it a no-op.
STAGE="$ROOT/bin/.stage-Homeport.app"
AGENT="dev.homeport.bridge"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT.plist"
AGENT_WAS_RUNNING=0
PIN="$ROOT/deploy/signing-identity.pin"

cleanup() {
    local rc=$?
    rm -rf "$STAGE"
    # Only fires if we failed AFTER stopping the agent, which is now a
    # millisecond-wide window rather than the whole signing step.
    if [[ $rc -ne 0 && "$AGENT_WAS_RUNNING" == "1" ]] \
       && ! launchctl print "gui/$(id -u)/$AGENT" >/dev/null 2>&1; then
        echo "!! build failed after stopping $AGENT -- restarting it" >&2
        launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || true
    fi
    return $rc
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Resolve the signing identity BEFORE anything destructive happens.
#
# Signing by common name is not safe here. A host that has run BOTH
# deploy/bootstrap-host.sh (user keychain) and deploy/install-signing-identity.sh
# (system keychain) ends up with two self-signed certs both called
# "Apple MCP Bridge", and `codesign -s "Apple MCP Bridge"` then fails outright
# with `ambiguous (matches ... and ...)`. Worse than failing: if it ever
# resolved to the OTHER cert, the designated requirement changes and all five
# privacy grants drop -- and Full Disk Access cannot be re-prompted, only
# re-added by hand at the machine.
#
# So resolve to an unambiguous SHA-1, and prefer the SYSTEM keychain: it is the
# only one an SSH session can reach, so remote rebuilds pick the same cert an
# interactive one does.
# ---------------------------------------------------------------------------
SYSTEM_KEYCHAIN="/Library/Keychains/System.keychain"

identity_hashes() {  # $1 = common name; prints one SHA-1 per line
    local want="$1" found
    found="$(security find-identity -v -p codesigning "$SYSTEM_KEYCHAIN" 2>/dev/null \
             | awk -v n="\"$want\"" 'index($0, n) {print $2}')"
    if [[ -z "$found" ]]; then
        found="$(security find-identity -v -p codesigning 2>/dev/null \
                 | awk -v n="\"$want\"" 'index($0, n) {print $2}' | sort -u)"
    fi
    printf '%s\n' "$found" | grep . || true
}

echo "==> Resolving signing identity"
WANTED="${CODESIGN_IDENTITY:-Apple MCP Bridge}"
SIGN_ID=""
if [[ "$WANTED" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    SIGN_ID="$WANTED"                       # already a hash; nothing to resolve
else
    HASHES="$(identity_hashes "$WANTED")"
    COUNT="$(printf '%s\n' "$HASHES" | grep -c . || true)"
    if [[ "$COUNT" == "1" ]]; then
        SIGN_ID="$HASHES"
    elif [[ "$COUNT" -gt 1 ]]; then
        echo "!! '$WANTED' matches $COUNT identities and none of them is in the system keychain:" >&2
        printf '%s\n' "$HASHES" | sed 's/^/     /' >&2
        echo "   Signing by name would be ambiguous. Pass the SHA-1 you want:" >&2
        echo "     CODESIGN_IDENTITY=<sha1> $0 $CONFIG" >&2
        echo "   Or drop the duplicate keychain from the search list:" >&2
        echo "     security list-keychains -d user -s \"\$HOME/Library/Keychains/login.keychain-db\"" >&2
        exit 1
    elif [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
        # Explicitly asked for an identity that is not there. Falling back to
        # ad-hoc would silently drop every grant, so refuse instead.
        echo "!! CODESIGN_IDENTITY='$CODESIGN_IDENTITY' matches no codesigning identity." >&2
        echo "   Available:" >&2
        security find-identity -v -p codesigning 2>&1 | sed 's/^/     /' >&2
        exit 1
    fi
fi

if [[ -n "$SIGN_ID" ]]; then
    WHERE="user keychain"
    security find-identity -v -p codesigning "$SYSTEM_KEYCHAIN" 2>/dev/null \
        | grep -q "$SIGN_ID" && WHERE="system keychain"
    echo "    $SIGN_ID ($WANTED, $WHERE)"

    # Prove the key is actually usable before tearing anything down. An
    # identity can be listed and still fail to sign -- a locked keychain, or a
    # partition list that never got `codesign:` added.
    TRIAL="$(mktemp -d)"
    cp -f "$BINARY" "$TRIAL/probe"
    if ! codesign --force --options runtime -s "$SIGN_ID" "$TRIAL/probe" 2>"$TRIAL/err"; then
        echo "!! Trial signing failed -- refusing to touch the installed app." >&2
        sed 's/^/     /' "$TRIAL/err" >&2
        rm -rf "$TRIAL"
        exit 1
    fi
    rm -rf "$TRIAL"
    echo "    trial sign OK"
else
    echo "    No identity found -> ad-hoc signing (grants WILL reset on every rebuild)." >&2
fi

echo "==> Staging bundle"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS"
cp -f "$BINARY" "$STAGE/Contents/MacOS/Homeport"
cp -f "$PLIST" "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

echo "==> Signing"
# Sign the BUNDLE, not the inner executable. Signing the bundle seals
# Contents/Info.plist into the signature, which is what lets TCC trust the
# CFBundleIdentifier it reads from there.
if [[ -n "$SIGN_ID" ]]; then
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_ID" "$STAGE"
else
    codesign --force --entitlements "$ENTITLEMENTS" --sign - "$STAGE"
fi

echo "==> Verifying"
codesign --verify --strict "$STAGE" && echo "    signature verifies."
# Capture once rather than piping twice: with `set -o pipefail`, `grep -q`
# exiting early SIGPIPEs codesign and the pipeline reports failure on success.
SIGINFO="$(codesign -d --verbose=4 "$STAGE" 2>&1 || true)"
BUNDLE_ID="$(printf '%s\n' "$SIGINFO" | sed -n 's/^Identifier=//p')"
echo "    bundle identifier: $BUNDLE_ID"
if printf '%s\n' "$SIGINFO" | grep -q 'Sealed Resources'; then
    echo "    Info.plist sealed into the signature (TCC will key on the bundle id)."
else
    echo "    WARNING: no sealed resources -- TCC may still key on the path." >&2
fi
if strings "$STAGE/Contents/MacOS/Homeport" | grep -q "NSRemindersFullAccessUsageDescription"; then
    echo "    usage strings present."
else
    echo "    WARNING: could not confirm usage strings." >&2
fi

# The designated requirement IS the TCC identity.
#
# Every grant this app holds -- Calendar, Reminders, Contacts, Full Disk Access,
# Automation for Notes and Messages -- is matched against this string. If it
# changes, all of them stop matching at once, and FDA has no prompt to re-fire:
# it can only be re-added by hand in System Settings. So it is pinned to a file
# and compared on every build, loudly, rather than discovered a day later when
# the voice-memo pipeline quietly stops filing anything.
DR="$(codesign -d -r- "$STAGE" 2>/dev/null | sed -n 's/^designated => //p')"
if [[ -z "${DR:-}" ]]; then
    echo "    WARNING: could not read the designated requirement." >&2
elif [[ ! -f "$PIN" ]]; then
    mkdir -p "$(dirname "$PIN")"
    printf '%s\n' "$DR" > "$PIN"
    echo "    designated requirement pinned to deploy/$(basename "$PIN")"
elif [[ "$DR" == "$(cat "$PIN")" ]]; then
    echo "    designated requirement unchanged (TCC grants carry over)."
else
    echo "" >&2
    echo "!! DESIGNATED REQUIREMENT CHANGED -- every privacy grant will be dropped." >&2
    echo "     was: $(cat "$PIN")" >&2
    echo "     now: $DR" >&2
    echo "   You signed with a different certificate. Re-run with the right identity," >&2
    echo "   or accept it and re-grant: open -a bin/Homeport.app --args --grant," >&2
    echo "   then re-add Full Disk Access by hand in System Settings." >&2
    echo "   To accept: rm '$PIN' and build again." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Swap. Everything above this line is reversible; this is the only destructive
# step, and it is now two filesystem operations long.
#
# The daemon has to stop first: overwriting the binary of a RUNNING
# hardened-runtime process invalidates its signature and macOS kills it
# ("last exit reason = OS_REASON_CODESIGNING"). KeepAlive restarts it, so it
# looks harmless -- but the kill lands mid-request and any in-flight tailnet
# call dies with an empty response.
# ---------------------------------------------------------------------------
if launchctl print "gui/$(id -u)/$AGENT" >/dev/null 2>&1; then
    AGENT_WAS_RUNNING=1
    echo "==> Stopping $AGENT"
    launchctl bootout "gui/$(id -u)/$AGENT" 2>/dev/null || true
fi

echo "==> Installing $APP"
rm -rf "$APP"
mv "$STAGE" "$APP"
BINARY="$APP/Contents/MacOS/Homeport"

if [[ "$AGENT_WAS_RUNNING" == "1" ]]; then
    echo "==> Restarting $AGENT"
    launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || true
    # Confirm it actually came back rather than assuming. A bundle that fails to
    # launch leaves the tailnet endpoint dead, and the only symptom elsewhere is
    # a connection refused ten minutes later.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        launchctl print "gui/$(id -u)/$AGENT" 2>/dev/null | grep -q "state = running" && break
        sleep 0.5
    done
    if launchctl print "gui/$(id -u)/$AGENT" 2>/dev/null | grep -q "state = running"; then
        echo "    running."
    else
        echo "    WARNING: $AGENT did not come back up. Check ~/Library/Logs/homeport.err.log" >&2
    fi
fi

echo ""
echo "Done. App at:"
echo "    $APP"
echo "Executable:"
echo "    $BINARY"
echo ""
echo "Register with Claude Code:"
echo "    claude mcp add homeport -- \"$BINARY\""
