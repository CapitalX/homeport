# Features not carried over from the source projects

This server was **built fresh** (single self-contained Swift binary), not forked. It reuses the *TCC/permission approach* from the MIT-licensed [`FradSer/mcp-server-apple-events`](https://github.com/FradSer/mcp-server-apple-events) but none of its application code. The items below exist in one or more of the surveyed projects and were **intentionally left out** — listed so you know exactly what's missing versus the ecosystem.

| Feature | Where it exists upstream | Carried over? | Why / note |
|---|---|---|---|
| **Reminder subtasks / checklist items** | FradSer (emulated), some others faked in notes | ❌ No | EventKit has no public subtask API. Upstreams emulate via a notes parser, which is fragile (FradSer's own repo shows repeated churn here). Omitted rather than faked. |
| **Reminder tags** | FradSer, snarris (`#tag` in notes) | ❌ No | Native Reminders tags need private APIs; the `#tag`-in-notes emulation pollutes the notes body. Omitted. |
| **Location / geofence alarms on reminders** | Krishna-Desiraju (arrive/depart + radius) | ❌ No | Time-based alarms are supported; geofenced alarms were scoped out. Straightforward to add later via `EKStructuredLocation` + `EKAlarm.structuredLocation`. |
| **HTTP / remote transport** | farmerajf, FradSer (partial) | ✅ **Since added** | Now a first-class transport, but with no API key: the listener binds `127.0.0.1` and `tailscale serve` fronts it, so identity comes from WireGuard rather than a shared secret there is no way to rotate or keep out of logs. |
| **Cloud data sync (Cloudflare D1) + encryption layer** | FradSer (`apple-sync-kit`, `EventEncryptor`) | ❌ No | Irrelevant for a local tool, and `apple-sync-kit` is a private dependency that complicates building. Deliberately excluded. |
| **Messages tools** | orchard-mcp, griches | ✅ **Since added** | Read is a direct `chat.db` query (tapbacks, group names, participants decoded properly). Send exists but is gated behind an explicit recipient allowlist, because moving data to another person is its whole purpose. |
| **Mail / Files / Maps / iWork tools** | orchard-mcp (~65 tools), griches | ❌ No | Out of scope. |
| **Notes tools** | orchard-mcp, griches | ✅ **Since added** | Originally out of scope, but the voice-memo pipeline needs a destination for filed summaries. Added as `notes_folders`/`notes_create`/`notes_append` over Apple Events. Still no `notes_delete` (destructive, and nothing needs it yet) and no checklist support (Notes exposes no scriptable checklist type). |
| **Writing event attendees / sending invites** | attempted via AppleScript in griches | ❌ No | EventKit cannot add attendees to an `EKEvent` programmatically (Apple limitation). Attendees + organizer are exposed **read-only**. No project does this reliably via EventKit. |
| **Contact notes field** | — | ❌ No | Requires Apple's `com.apple.developer.contacts.notes` entitlement; requesting the key without it throws. Excluded so reads never crash. |
| **Larger prompt-template library** | FradSer (4 reminders-centric prompts) | ➖ Partial | We ship 4 prompts (`daily-agenda`, `weekly-planning`, `capture-reminder`, `inbox-triage`) spanning calendar + reminders. |

## What this server has that most upstreams don't

- **Recurrence *writes*** on both reminders and events (FradSer and orchard expose recurrence read-only).
- **Alarm *writes*** on both reminders and events.
- **Contacts CRUD** in the same binary (most Calendar/Reminders servers don't touch Contacts).
- **Single signed binary** owning one TCC identity (vs. Node→CLI or Python-interpreter splits that fragment the grant).
- **Explicit macOS 14.2.x `granted=false/error=nil` hardening** — not handled by any surveyed project.

## What this project has that the surveyed upstreams do not

| Capability | Note |
|---|---|
| **Recurrence and alarm _writes_** | FradSer and orchard expose recurrence read-only; here it is writable on both events and reminders, including `bySetPos` ("last Friday of the month") and occurrence-level splits. |
| **Voice Memos** | Not in any surveyed project. Reads the library read-only, parses the transcript iOS embeds in `.qta` files, and transcribes Mac recordings on-device. |
| **Bulk reminder operations** | One change applied across many reminders in a single call, targeted by id or filter. |
| **Runs headless as a daemon** | Every surveyed project is spawned by its client and dies with it. The disclaim shim is what makes an independent daemon possible at all. |
| **Prompt-injection defenses** | Untrusted content fenced with a per-response nonce; tool trust classification fails closed; sends restricted to an allowlist; audit log that records metadata and never content. |
| **Single binary, no runtime** | FradSer ships a TypeScript server that spawns a vendored Swift CLI. Here one signed binary is both, so exactly one identity owns every grant. |
