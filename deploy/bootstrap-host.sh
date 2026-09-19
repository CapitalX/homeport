#!/bin/bash
# One-time privileged setup for a new bridge host.
#
# Everything else in this project is scriptable over SSH. These three things are
# not, so they are batched here to cost exactly one password prompt:
#
#   1. Trusting the local code-signing certificate. codesign refuses an
#      untrusted identity, and without a real identity the signature is ad-hoc
#      -- which pins the TCC csreq to one build's cdhash, so every rebuild
#      would silently drop all five privacy grants.
#   2. Disabling sleep. An always-on service cannot be asleep.
#   3. Creating the identity itself, if it does not exist yet.
#
# Run this in Terminal ON THE MACHINE (or any session that can prompt).
# Safe to re-run.
set -uo pipefail

NAME="Apple MCP Bridge"
CFGDIR="$HOME/.config/homeport"
KC="$CFGDIR/signing.keychain"
PASSFILE="$CFGDIR/signing-keychain-password"

echo "==> 1/3  code-signing identity"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
    echo "    already present and trusted"
else
    mkdir -p "$CFGDIR"; chmod 700 "$CFGDIR"
    if [ ! -f "$PASSFILE" ]; then
        LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40 > "$PASSFILE"; chmod 600 "$PASSFILE"
    fi
    PASS="$(cat "$PASSFILE")"

    if ! security find-identity "$KC" 2>/dev/null | grep -q "$NAME"; then
        security delete-keychain "$KC" 2>/dev/null || true; rm -f "$KC" "$KC-db"
        security create-keychain -p "$PASS" "$KC"
        security set-keychain-settings "$KC"
        security unlock-keychain -p "$PASS" "$KC"
        TMP=$(mktemp -d)
        /usr/bin/openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
            -days 3650 -nodes -subj "/CN=$NAME/O=homeport" \
            -addext "basicConstraints=critical,CA:false" \
            -addext "keyUsage=critical,digitalSignature" \
            -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
        # Legacy PBE is REQUIRED: with OpenSSL's modern defaults `security
        # import` reads the certificate but silently drops the private key, so
        # you get "1 identity imported" and then zero usable identities.
        /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
            -out "$TMP/id.p12" -passout pass:tmp -name "$NAME" \
            -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg SHA1 2>/dev/null
        security import "$TMP/id.p12" -k "$KC" -P tmp -T /usr/bin/codesign -A >/dev/null
        security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null 2>&1
        cp "$TMP/cert.pem" "$CFGDIR/signing-cert.pem"
        rm -rf "$TMP"
        echo "    identity created in $KC"
    fi
    security list-keychains -d user -s "$HOME/Library/Keychains/login.keychain-db" "$KC"

    # The PEM is only written when the identity is created. If the keychain was
    # made by an earlier run (or by hand) the file is absent, and add-trusted-cert
    # then fails on a path that never existed. Re-export it from the keychain
    # rather than assuming the create branch ran.
    if [ ! -s "$CFGDIR/signing-cert.pem" ]; then
        security unlock-keychain -p "$(cat "$PASSFILE")" "$KC" 2>/dev/null
        security find-certificate -c "$NAME" -p "$KC" > "$CFGDIR/signing-cert.pem" 2>/dev/null
    fi
    if [ ! -s "$CFGDIR/signing-cert.pem" ]; then
        echo "    cannot find the certificate to trust; delete $KC and re-run"
        exit 1
    fi

    echo "    trusting it for code signing (this is the password prompt)"
    sudo security add-trusted-cert -d -r trustRoot -p codeSign \
        -k /Library/Keychains/System.keychain "$CFGDIR/signing-cert.pem" \
        && echo "    trusted" || echo "    TRUST FAILED"
fi

echo "==> 2/3  never sleep"
sudo pmset -a sleep 0 displaysleep 0 disksleep 0 womp 1 autorestart 1 >/dev/null 2>&1 \
    && echo "    sleep disabled, wake-on-lan and auto-restart-on-power-loss on" \
    || echo "    pmset FAILED"

echo "==> 3/3  verify"
security unlock-keychain -p "$(cat "$PASSFILE" 2>/dev/null)" "$KC" 2>/dev/null
security find-identity -v -p codesigning 2>/dev/null | grep "$NAME" || echo "    identity still not valid"
pmset -g custom | grep -A8 "AC Power" | grep -E "^ sleep" | sed 's/^/    /'
echo
echo "Done. Nothing else on this machine needs your password."
