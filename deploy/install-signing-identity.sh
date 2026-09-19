#!/bin/bash
# Put the code-signing identity where an SSH session can actually use it.
#
# WHY THE SYSTEM KEYCHAIN. An interactive login gets the user's keychain
# context; an SSH session does not -- its default keychain is
# /Library/Keychains/System.keychain, it cannot unlock login.keychain, and a
# user search list set with `security list-keychains` is ignored. An identity
# in a user keychain is therefore invisible to `codesign` over SSH, which
# silently falls back to an AD-HOC signature.
#
# That fallback is the thing to avoid: ad-hoc pins the TCC csreq to one build's
# cdhash, so every rebuild drops all five privacy grants and they have to be
# re-granted by hand at the machine.
#
# Putting key + cert in the system keychain makes unattended remote rebuilds
# work permanently. Run once, with sudo. Idempotent.
set -uo pipefail

NAME="Apple MCP Bridge"
SYS=/Library/Keychains/System.keychain

[ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo $0" >&2; exit 1; }

if security find-identity -v -p codesigning "$SYS" 2>/dev/null | grep -q "\"$NAME\""; then
    echo "identity already usable from the system keychain"
    security find-identity -v -p codesigning "$SYS" | grep "$NAME"
    exit 0
fi

# Refuse to mint a SECOND cert with this common name.
#
# deploy/bootstrap-host.sh creates the same identity in a user keychain. If both
# scripts run, `codesign -s "Apple MCP Bridge"` becomes literally ambiguous
# ("matches ... and ...") and every build fails -- or worse, resolves to the
# other cert, which changes the app's designated requirement and drops all five
# privacy grants at once. Full Disk Access has no prompt to re-fire.
EXISTING="$(security find-identity -v -p codesigning 2>/dev/null | grep "\"$NAME\"" || true)"
if [ -n "$EXISTING" ] && [ "${1:-}" != "--force" ]; then
    echo "!! '$NAME' already exists outside the system keychain:" >&2
    printf '%s\n' "$EXISTING" | sed 's/^/   /' >&2
    echo >&2
    echo "   Creating a second cert with the same name makes \`codesign -s\` ambiguous and" >&2
    echo "   changes the app's designated requirement, which drops every TCC grant." >&2
    echo >&2
    echo "   Either keep using that one, or drop its keychain from the search list first:" >&2
    echo "     security list-keychains -d user -s \"\$HOME/Library/Keychains/login.keychain-db\"" >&2
    echo "   then re-run. Pass --force to create it anyway (you will have to re-grant" >&2
    echo "   Calendar, Reminders, Contacts, Full Disk Access and Automation by hand)." >&2
    exit 1
fi

# Drop any earlier cert-only copy so we do not end up with two certs and no key.
security delete-certificate -c "$NAME" "$SYS" 2>/dev/null || true

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
/usr/bin/openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -subj "/CN=$NAME/O=homeport" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# Legacy PBE is mandatory. With OpenSSL's modern defaults `security import`
# reads the certificate and silently discards the private key -- you get
# "1 identity imported" followed by zero usable identities.
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass:tmp -name "$NAME" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg SHA1 2>/dev/null

security import "$TMP/id.p12" -k "$SYS" -P tmp -T /usr/bin/codesign -A >/dev/null 2>&1 \
    && echo "imported key + certificate into the system keychain"
security add-trusted-cert -d -r trustRoot -p codeSign -k "$SYS" "$TMP/cert.pem" >/dev/null 2>&1 \
    && echo "trusted for code signing"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$SYS" >/dev/null 2>&1 || true

echo "--- verify ---"
security find-identity -v -p codesigning "$SYS" 2>&1 | grep "$NAME" || echo "STILL NOT VALID"

T2=$(mktemp -d); printf 'int main(){return 0;}' > "$T2/t.c"; cc -o "$T2/t" "$T2/t.c" 2>/dev/null
codesign --force --options runtime -s "$NAME" "$T2/t" 2>&1 | sed 's/^/  /'
codesign -dv "$T2/t" 2>&1 | grep -E "Authority|Signature" | sed 's/^/  /'
rm -rf "$T2"
