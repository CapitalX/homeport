# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single self-contained Swift binary that is **both** an MCP server and the EventKit/Contacts/Notes/Voice-Memos/Messages/Shortcuts engine behind it. `bridge_ping` reports the running version and `toolCount`. The server needs no Node and no Python runtime (the optional watcher and deploy scripts use Python 3), and no library/executable split — that is a deliberate design constraint, not an accident: one binary means exactly one code-signing identity owns the macOS TCC grant, which is the whole reason this project exists (see `README.md` § "Why another Apple MCP server?").

## Commands

```bash
./build.sh release            # build + embed Info.plist + assemble .app + sign  (the ONLY supported build)
./build.sh debug              # same pipeline, debug config
swift test                    # unit tests (pure functions; no TCC grant needed)
swift test --filter UntrustedTests/testEveryRegisteredToolIsClassified   # one test
./deploy/healthcheck.sh       # verify the whole deployment ON THIS HOST (run after a rebuild, reboot or OS update)
BRIDGE_ENDPOINT=https://<bridge-host>.<tailnet>.ts.net/mcp ./pipeline/selftest.sh   # end-to-end — RUN FROM ANOTHER TAILNET NODE (prints its own totals)
BRIDGE_ENDPOINT=... ./pipeline/selftest.sh --write   # also exercises create/update/delete
./deploy/install-bridge.sh    # (re)install the LaunchAgent pointing at bin/…/Homeport
./pipeline/add-device.sh <node> [read,write,message]   # enroll a tailnet device in policy.json
```

`selftest.sh` cannot test the host it runs on. `tailscale serve` stamps
`Tailscale-User-Login` only on requests from a *peer*, so a request the bridge host makes to its own
endpoint carries no identity and the bridge — correctly — 401s every one of them. The script detects
this and exits 78 with instructions rather than reporting a wall of phantom failures. Do not write a
check count into the docs: it changes as tools are added, and differs with `--write`. `deploy/healthcheck.sh`
is the on-host counterpart: it checks the installation rather than the tools.

**Never use plain `swift build` to produce a usable binary.** `build.sh` does three things `swift build` cannot: it links the `Info.plist` into `__TEXT,__info_plist` (without it TCC prompts never fire), it wraps the Mach-O in a real `.app` bundle (a bare Mach-O is keyed by absolute path, so `tccutil` cannot target it and moving the directory drops every grant), and it code-signs the bundle. `swift build` is fine for a compile check only.

`build.sh` also stops and restarts the `dev.homeport.bridge` LaunchAgent around the copy — overwriting a running hardened-runtime binary gets the process killed for a code-signing violation mid-request.

### Signing is the TCC identity

Every grant the app holds — Calendar, Reminders, Contacts, Full Disk Access, Automation for Notes and
for Messages — is matched against its **designated requirement**, which for a self-signed identity is
`identifier "dev.homeport.bridge" and certificate root = H"<cert sha1>"`. Change the
certificate and all of them stop matching at once. Four consequences, all enforced in `build.sh`:

- **The DR is pinned** in `deploy/signing-identity.pin` and compared on every build. A mismatch aborts
  rather than shipping a bundle whose grants have silently evaporated. To accept a new identity
  deliberately, delete the pin and rebuild — then re-run `--grant` and re-add Full Disk Access by hand,
  because FDA has no prompt to re-fire.
- **Identities resolve by SHA-1, preferring the system keychain**, never by common name.
  `deploy/bootstrap-host.sh` puts an "Apple MCP Bridge" cert in a user keychain and
  `deploy/install-signing-identity.sh` puts one in the system keychain; a host that ran both has two
  certs with the same name, and `codesign -s "Apple MCP Bridge"` then fails outright with
  `ambiguous (matches … and …)`. `install-signing-identity.sh` now refuses to mint a duplicate
  without `--force`.
- **The build stages and swaps.** Signing happens on `bin/.stage-Homeport.app`, and the installed
  bundle is only replaced once the signature and the pin both check out. The old order stopped the
  agent and `rm -rf`'d the app *before* signing, so under `set -e` any signing failure left the host
  with no bundle and no service — and `KeepAlive` cannot restart a binary that does not exist.
- **Ad-hoc is a last resort.** It changes the code hash every rebuild, dropping every grant. An
  explicitly-set `CODESIGN_IDENTITY` that resolves to nothing is now a hard error rather than a silent
  fallback to ad-hoc.

## Architecture

### Startup (`main.swift`)

Three ordered steps, and the order is load-bearing: `--grant` bootstrap (must precede the re-exec — a disclaimed process has no GUI session and macOS will not prompt it) → `Disclaim.reexecIfNeeded()` (re-exec self via `responsibility_spawnattrs_setdisclaim` so the TCC grant attaches to *this* binary rather than to Claude Desktop/Code) → serve.

### Transport selection

`HOMEPORT_HTTP_PORT` decides: unset → `StdioTransport` (local MCP clients spawn it this way), set → `HTTPTransport` on **127.0.0.1 only**, fronted by `tailscale serve`. The loopback bind *is* the security boundary. Transport is an env var and not a flag because the disclaim re-exec propagates the environment explicitly. The listener must be created after the re-exec.

### Request lifecycle — the chokepoint

Everything funnels through `MCPServer.handleToolCall` → `respondTool`. That single exit is where the audit record and the `Untrusted` envelope are applied. `NoteGuard.filter` runs on every *successful* result and on idempotency replays, just before `respondTool`; error strings do not pass through it, so **an error message must never include note content**. Do not build a `content` block anywhere but `respondTool`.

Order inside `handleToolCall`: strip `idempotencyKey` → idempotency replay (which re-runs `NoteGuard`, because the replay path never enters the handler) → unknown-argument rejection → handler → `NoteGuard.filter` → record idempotency (successes only) → `respondTool`.

### The security layers, and what each one actually is

| Layer | File | What it answers | Boundary? |
|---|---|---|---|
| `TailnetIdentity` | `TailnetIdentity.swift` | who is calling (headers `tailscale serve` overwrites; no tokens, no secrets on disk). `X-Forwarded-For` is required; `Tailscale-User-Login` is optional because serve sends none for **tagged** devices, whose only gate is enrollment by address | HTTP only |
| `Auth` | `Auth.swift` | what that node may do (`policy.json` scopes; **fails closed**) | HTTP only |
| `NoteGuard` | `NoteGuard.swift` | may this Notes content be *returned* (`readBlockedNoteFolders`) | every transport; a guardrail, not a boundary |
| `Untrusted` | `Untrusted.swift` | is this payload attacker-authored (nonce-fenced envelope) | defense in depth |
| recipient allowlist | `Auth.Policy.allowedRecipients` | may `messages_send` deliver here | the real boundary for the one irreversible tool |
| `AuditLog` | `AuditLog.swift` | who did what to which record — **never content** | — |

`Auth` and `NoteGuard`/recipient-allowlist live at different places on purpose: `Auth` only runs for HTTP, so any rule that must also hold for stdio is enforced at the shared chokepoint or in the tool handler instead.

### Adding or renaming a tool

Three tables must stay in sync, and two of them fail closed (so forgetting is a security *default*, not a hole — but the tests still fail):

1. Register it in the `MCPServer.init` concatenation of `<Family>Tools.all` arrays.
2. `Auth.toolScopes` — unlisted ⇒ requires `write`. Read-only tools **must** be listed or they are unreachable to read-only nodes. This also drives whether `idempotencyKey` is injected into the schema.
3. `Untrusted.toolTrust` — unlisted ⇒ `.untrusted`. `UntrustedTests` asserts the table is exhaustive *and* has no stale entries, so both directions break the build.

Schemas use the `Schema.*` helpers and set `additionalProperties: false`; unknown arguments are actively rejected with the accepted list rather than ignored, because a silently dropped filter looks like success to a model.

**That check only sees top-level keys.** `MCPServer.unknownArguments` compares `args.keys` against the
schema's `properties` and cannot look inside an array or a nested object. A tool that accepts nested
objects must therefore validate them itself, or it silently reinstates exactly the failure the
top-level check exists to prevent. `reminders_bulk_create` is the worked example:
`ReminderTools.validateBulkItem` re-implements the check per `items[]` entry (reporting the index, so
"one of your 50 rows is wrong" is actionable), and `BulkCreateTests` asserts its accepted field set
equals `reminders_create`'s schema properties **exactly** — so adding a field to one and forgetting
the other turns into a red build rather than a field the bulk path rejects as unknown.

### Conventions that are not negotiable

- **stdout is the JSON-RPC stream.** All diagnostics go to stderr via `Log` (prefix `[homeport]`).
- **No shelling out.** Notes is driven by in-process `NSAppleScript`, never `osascript` — shelling out would attribute the Automation grant to `osascript` and fragment the single-identity TCC story. Nothing shells out to a JSON tool either; parsing is `JSONSerialization` throughout. **The one exception is `/usr/bin/shortcuts`**, which has no in-process equivalent: it is spawned only from `ShortcutsTools.runCLI`, always with a hard deadline. Do not add a second call site, and do not use that one as precedent for anything touching a TCC-guarded domain.
- **One request at a time.** HTTP accepts concurrently but every dispatch hops onto one serial queue. Handlers may assume no concurrency.
- **Read-only against Voice Memos.** `CloudRecordings.db` is copied (with `-wal`/`-shm`) to a temp dir and read there; never opened in place.
- **Summaries in a confidential category never return to the caller.** They are written straight into Notes. `confirmMayLeaveMachine: true` is the deliberate escape hatch. This rule is enforced in code — do not "helpfully" return the text.
- Destructive tools require an explicit flag: `confirmDelete` for event, reminder and contact deletion, `confirm` for merges and `shortcuts_run`, `confirmReplace` for replacing or adding to a contact's phones/emails/URLs (refused with an error, not previewed, without it). **Deleting a whole calendar or reminder list (`action: delete`) currently takes no confirmation.**

## Surviving reboots and macOS updates

`deploy/healthcheck.sh` checks every link in this chain; the reasoning behind each one:

- **The bridge is a LaunchAgent, not a LaunchDaemon, and it has to be.** EventKit, Contacts, Notes and
  Apple Events all require a user session — a daemon in the system domain can never reach them. The
  cost is that `gui/<uid>` only exists once somebody logs in, so on an unattended machine
  **automatic login is load-bearing**: without it a reboot leaves the endpoint dead until a human sits
  down. FileVault has the same effect, since the disk unlock happens before any auto-login.
- **`RunAtLoad` + `KeepAlive`** bring it back at login and after a crash. `build.sh` verifies the agent
  actually returned after the swap instead of assuming it.
- **`tailscaled` is a system LaunchDaemon**, so the tailnet is up before login, and `tailscale serve
  --bg` persists its config in tailscaled's state — the HTTPS endpoint reappears without anyone
  re-running it.
- **`pmset sleep 0`** (set by `deploy/bootstrap-host.sh`, along with `autorestart 1` for power loss):
  a sleeping Mac is an unreachable endpoint, and from a client it looks identical to a crashed daemon.
- **TCC grants survive an OS update** because the DR is keyed on bundle id + certificate, not on a path
  or a code hash. They do *not* survive a certificate change — see the signing section.
- **`bin/` is gitignored**, so the app bundle exists only on the host that built it. A `git clean -xfd`
  deletes the running service's binary. After any fresh clone: `./build.sh release` then
  `./deploy/install-bridge.sh`.

### Bulk tools and the filter gate

`BatchTarget` (`BatchTarget.swift`) is the shared targeting layer for `reminders_bulk_update` and
`reminders_bulk_delete`: `ids` XOR `filter`, resolved to concrete reminders **before** any mutation so
a preview is never assembled from half-changed state and a bad id surfaces while the batch is still
reversible. Reuse it for any bulk tool added later rather than re-deriving the rules.

The gate worth understanding: a `filter` requires `expectedCount`, and that number cannot be known
without first calling without it and reading the preview. That makes previewing **structural** rather
than a convention a caller can skip, and it doubles as a race check — an iCloud sync from another
device between preview and call changes the count, and the mismatch aborts. `confirmDelete` sits on
top of that for the irreversible tool; the two gates are independent and both must be cleared.

Filters speak the `reminders_query` vocabulary exactly (`BatchTargetTests` asserts the field set is a
subset of that schema), so reading and acting share one mental model.

### Shortcuts (`ShortcutsTools.swift`)

`shortcuts_build` / `_fetch` / `_list` / `_run`, driven by `/usr/bin/shortcuts`. README § Shortcuts has
the full account; the findings that will bite someone editing this file (measured on macOS 26.6.2):

- **No code can mint an `icloud.com/shortcuts` link** — no API, CLI verb, AppleScript verb or action.
  Only Shortcuts.app as the account owner writes that CloudKit record. Do not try to automate it;
  `shortcuts_build` returns a signed file plus the manual step, and `shortcuts_fetch attachTo:` records
  the link only if the shared name matches the build.
- **`shortcuts sign` infers type from the input extension.** Write `.wflow`/`.shortcut`, never
  `.plist`, or it refuses with "isn't in the correct format".
- **A successful sign proves nothing about the actions.** It validates plist structure only; a fake
  action identifier signs fine. The result must not imply otherwise.
- **The file name is the shortcut's name** in the library; nothing in the plist carries one. Artifacts are
  named by `fileName` (keeps spaces/capitals), and `slug` is only the manifest key and `attachTo` handle.
- **Opening a signed file on macOS imports it immediately**, no confirmation. AppleScript's `action count`
  is `0` for any shortcut never opened in the editor, so it is useless as an import check; run the shortcut instead.
- **Every CLI call goes through `runCLI` with a hard deadline.** `shortcuts run` blocks forever on a
  shortcut that wants input and `shortcuts sign` blocks with no iCloud session; either would wedge the
  one serial dispatch queue.
- **Callers never choose a path.** Output is confined to the outbox (below), or this becomes an
  arbitrary-file-write primitive over the tailnet. Asset downloads are pinned to `icloud.com` /
  `icloud-content.com`. `shortcuts_run` requires `confirm: true`.
- Scopes: `list`/`fetch` are `read`, `build`/`run` are `write`. Trust: `build` is `.trusted` (echoes the
  caller's own input); `fetch`, `list` and `run` are `.untrusted`, since shared shortcuts are strangers'
  programs and keep the sharer's chosen name.

## Runtime files (not in the repo)

| Path | What |
|---|---|
| `~/Library/Application Support/homeport/policy.json` | allowed users, enrolled nodes + scopes, `readBlockedNoteFolders`, `allowedRecipients`. Policy, not credentials. Missing/malformed ⇒ reject everything. |
| `~/Library/Application Support/homeport/voicememo-watch.py` | the *installed* copy of the watcher (`pipeline/install.sh` copies it; launchd cannot read the repo copy under some TCC-protected paths) |
| `~/Library/Application Support/homeport/schedule.json` | `reminders_schedule` policy: hours, work-flag/protected/day-off calendars, list sets. Absent ⇒ neutral stock defaults. Never tracked; `deploy/schedule.example.json` shows every key |
| `~/Library/Application Support/homeport/shortcuts/` | the Shortcuts outbox: signed `.shortcut`, unsigned `.wflow`, per-build `<slug>.json` manifest, and `fetched-<id>.*` saves. The only place the Shortcuts tools write |
| `~/Library/Logs/homeport-audit.log` | one JSON object per line, rotated at 5 MB × 5 |
| `~/Library/Logs/homeport.{out,err}.log`, `voicememo-watch.log` | daemon + watcher output |
| `/Library/Keychains/System.keychain` | the code-signing identity, installed by `deploy/install-signing-identity.sh`. It lives in the **system** keychain on purpose: an SSH session's default keychain is the system one, it cannot unlock `login.keychain`, and a user search list set with `security list-keychains` is ignored — so an identity in a user keychain is invisible to `codesign` over SSH and it silently ad-hoc signs instead. |

Environment: `HOMEPORT_HTTP_PORT`, `HOMEPORT_LLM_URL`, `HOMEPORT_LLM_MODEL`, `HOMEPORT_RAW` (suppress the untrusted envelope — env var, never a tool argument, so a talked-into model cannot set it), `HOMEPORT_NO_DISCLAIM`, `HOMEPORT_AUTO_ROUTE` (opt in to routing reminders as they land; off by default).

## Host-specific paths

The repo root is not fixed — derive paths from it rather than copying them out of the docs. `deploy/install-bridge.sh`
generates the LaunchAgent from wherever the checkout actually is, and `pipeline/voicememo-watch.py` resolves the binary via
`HOMEPORT_BIN`, which `pipeline/install.sh` writes into its LaunchAgent.

The "TCC blocks launchd from reading `~/Desktop`" rationale in `pipeline/install.sh` only applies under that path, but copying
the watcher out of the repo is still the installed behaviour regardless.

## Getting a GUI-only thing done over SSH

TCC prompts need an Aqua session, and `open` from SSH fails with `error -600` — LaunchServices cannot cross into it. A launchd
agent bootstrapped into the `gui/<uid>` domain *does* run inside that session, so `--grant` can be driven remotely by writing a
one-shot agent, `launchctl bootstrap gui/$(id -u)` it, reading `~/Library/Logs/homeport-grant.log`, and booting it out.
Full Disk Access is the exception: there is no API for granting it, only `tccutil reset`, so it is added by hand once.

## Pre-publication sweep

Anything that could carry details of a real deployment must clear **three**
sweeps, not one. The third is the one that gets missed, which is why it is
written down.

### 1. Identifiers

```bash
grep -rIaniE "yourname|yourhost|yourtailnet|/Users/[a-z]+|@[a-z]+\.(com|net)|100\.[0-9]+\.[0-9]+\.[0-9]+" --exclude-dir=.git .
```

Hostnames, tailnet domains, usernames, absolute home paths, real addresses,
tailnet IPs, bundle identifiers containing an org name.

### 2. Git metadata

Content is not the only thing a commit carries.

```bash
git log --format='%an <%ae> | %cn <%ce>' --all | sort -u
git for-each-ref --format='%(refname:short) %(taggername) %(taggeremail)' refs/tags
```

With no `user.email` configured, git fabricates one from the hostname — which on
a Mac can embed the **machine UUID and the ISP's domain**. That is a stable
device identifier, in every commit and every tag, invisible in any file. Set
`user.email` to a GitHub noreply address before the first commit.

Note that rewriting history does **not** remove the old objects from GitHub:
force-pushing moves the refs, but the commits stay fetchable by SHA until
GitHub garbage-collects. If a bad commit was ever pushed, deleting and
recreating the repository is the only reliable fix.

### 3. Vocabulary — the one that gets missed

Grepping for identifiers finds nothing wrong with a word list. But **vocabulary
is disclosive**: a keyword list reveals what its author records, works on,
believes and worries about. A lexicon detailed enough to characterise its
operator's employer, routine and private life would pass any identifier sweep,
because not one of those words is an identifier.

Before publishing, read every **word list, prompt, example value, default
folder name, test fixture and code comment** and ask: *what does this tell a
stranger about the person who wrote it?*

```bash
# Adapt per domain -- the point is to grep for MEANING, not identifiers.
grep -rIaniE "<religious terms>|<employer tools>|<health or relationship terms>" --exclude-dir=.git .
```

Specific things to check, because they are easy to overlook:

- **Classifier lexicons and any keyword list** — the highest-risk artefact.
- **Prompt templates** — an extraction prompt that asks for domain-specific
  fields discloses the domain as surely as the word list does.
- **Tool descriptions and schema `enumValues`** — these are user-facing, and
  are easy to miss when the code behind them is cleaned.
- **Default folder names**, example config, and the `e.g.` in a schema string.
- **Time-window rules** — a recurring weekday-and-clock rule discloses a routine.
- **Code comments**, including ones explaining what was removed.

The structural fix is the one applied here: taxonomy is **configuration, not
code**. A stock build ships zero categories and classifies everything as
`unknown`. The operator's real `categories.json` lives in Application Support
and is never tracked. If a future feature wants to know something about its
operator, it should read it from config rather than embed it.

### Verify a stock build knows nothing

```bash
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | HOMEPORT_NO_DISCLAIM=1 HOMEPORT_RAW=1 ./.build/debug/Homeport \
  | python3 -c 'import json,sys
for l in sys.stdin:
    if l.startswith("{"):
        m=json.loads(l)
        if m.get("id")==2:
            for t in m["result"]["tools"]:
                if t["name"]=="voicememos_list":
                    print(t["inputSchema"]["properties"]["category"]["enum"])'
```

Must print `['unknown']`.
