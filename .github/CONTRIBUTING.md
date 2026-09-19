# Contributing to Homeport

Thanks for taking an interest. This is a macOS-only project that touches privacy-protected system data, so a few things work differently here than in a typical Swift package.

## Before you start

**You need a Mac you can grant permissions on.** Homeport talks to EventKit, Contacts, Notes and Messages through Apple's own frameworks. There is no mock backend — a change to a tool handler can only really be exercised against a machine with the grants in place.

**Read [`CLAUDE.md`](../CLAUDE.md) first.** It documents the architecture decisions that are load-bearing: the startup order, the single response chokepoint, and the three tables that must stay in sync when you add a tool.

## Setting up

```bash
git clone https://github.com/CapitalX/homeport.git
cd homeport
sudo ./deploy/install-signing-identity.sh
./build.sh
open -a bin/Homeport.app --args --grant
```

`swift build` alone produces a binary that **cannot work**. It does not link the `Info.plist` into `__TEXT,__info_plist` (without which permission prompts never fire), does not wrap the binary in a `.app` (a bare Mach-O is keyed by path, so grants break when you move the directory), and does not code-sign. Use `./build.sh`. `swift build` is fine as a compile check only.

## Tests

```bash
swift test               # unit tests, no permissions needed
./deploy/healthcheck.sh  # verifies the install on this host
BRIDGE_ENDPOINT=https://<bridge-host>.<tailnet>.ts.net/mcp ./pipeline/selftest.sh   # end-to-end, from a *peer* node
```

Unit tests cover logic that needs no Apple framework access — the classifier, the trust table, handle normalization, audit redaction, scheduling, Shortcuts confinement. They need no TCC grant and run in CI. Anything requiring a real grant belongs in `selftest.sh`.

`selftest.sh` cannot run on the bridge host itself: `tailscale serve` stamps no identity header on a same-node request, so it must come from another node.

## Adding a tool

Three tables must stay in sync. Two fail closed, so forgetting is a safe default rather than a hole — but the tests will still fail, on purpose:

1. Register it in the `MCPServer.init` concatenation of `<Family>Tools.all`.
2. **`Auth.toolScopes`** — unlisted means `write` is required. Read-only tools *must* be listed or read-only nodes cannot reach them.
3. **`Untrusted.toolTrust`** — unlisted means `.untrusted`. The test suite asserts this table is exhaustive *and* free of stale entries, so both directions break the build.

Schemas use the `Schema.*` helpers with `additionalProperties: false`. Unknown arguments are rejected with the accepted list rather than ignored — a silently dropped filter looks like success to a model, and a model cannot self-correct from that.

## Conventions that are not negotiable

- **stdout is the JSON-RPC stream.** Diagnostics go to stderr via `Log`.
- **Never shell out.** Notes is driven by in-process `NSAppleScript`, not `osascript` — shelling out would attribute the Automation grant to `osascript` and fragment the single-identity TCC story. The single exception is `/usr/bin/shortcuts`, spawned only from `ShortcutsTools.runCLI` with a hard deadline.
- **Build responses only at the shared chokepoint.** The untrusted envelope and audit record attach there, and the note guard filters successful results just before it. Never put note content in an error message: errors are not filtered.
- **One request at a time.** Handlers may assume no concurrency.
- **Destructive tools require an explicit `confirm*` flag** (without it they refuse). Whole-calendar and whole-list deletion are the current exceptions.

## Pull requests

- Keep the diff focused; unrelated cleanups in their own PR.
- Say which macOS version you tested on, and which capabilities you actually exercised.
- If you changed anything touching permissions, signing, or the response path, say how you verified it — `bridge_ping` output or a `healthcheck.sh` run is ideal.
- CI runs `swift build` and `swift test` on macOS. Both must pass.

## Reporting bugs

Permission problems are the most common issue and the hardest to diagnose from a description alone. Please include:

```bash
codesign -dv bin/Homeport.app 2>&1 | grep -E "Authority|Signature"
codesign -d --entitlements - bin/Homeport.app
./deploy/healthcheck.sh
```

**Never paste real personal data** — calendar contents, message text, contact details — into an issue. Tool names, error strings and the diagnostics above are enough.

## Security issues

Please do not open a public issue for a vulnerability. Report it privately through GitHub's security advisory flow on this repository.
