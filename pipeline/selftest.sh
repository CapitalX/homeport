#!/usr/bin/env bash
#
# End-to-end self test for the bridge, over the real Tailscale HTTPS endpoint.
#
#   BRIDGE_ENDPOINT=https://<bridge-host>.<tailnet>.ts.net/mcp ./selftest.sh
#   BRIDGE_ENDPOINT=... ./selftest.sh --write    # also exercise write paths
#
# Run it from ANOTHER enrolled tailnet device, pointed at the bridge host.
# Read-only mode writes nothing and is safe to run any time, including right
# after a reboot.
# --write mode creates throwaway records, asserts against them, and deletes them
# again. Everything it creates is prefixed ZZSelfTest.
#
# SCOPING -- read this before changing it:
#   Calendar events go to a named calendar (SELFTEST_CALENDAR, default
#   "Personal"), never the default one. The default calendar may be shared, and
#   a test event landing in a calendar someone else sees is not an acceptable
#   failure mode. The script aborts rather than falling back to the default if
#   the named calendar is missing. Reminders go to SELFTEST_LIST (default
#   "Inbox") for the same reason.
set -uo pipefail

# Find the CLI rather than hardcoding one install layout: Tailscale may be
# installed as Tailscale.app or as the open-source brew daemon with no GUI.
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
TS="$(find_tailscale || true)"

# This node's MagicDNS name, to detect running on the bridge host itself.
SELF_DNS="$([[ -n "$TS" ]] && "$TS" status --json 2>/dev/null | python3 -c "
import json,sys
try: print((json.load(sys.stdin)['Self'].get('DNSName') or '').rstrip('.'))
except Exception: print('')")"
if [[ -z "${BRIDGE_ENDPOINT:-}" ]]; then
    echo "Set BRIDGE_ENDPOINT to the bridge's URL, e.g." >&2
    echo "    BRIDGE_ENDPOINT=https://<bridge-host>.<tailnet>.ts.net/mcp $0" >&2
    echo "and run this from another enrolled tailnet device." >&2
    exit 64   # EX_USAGE
fi
ENDPOINT="$BRIDGE_ENDPOINT"
CALENDAR="${SELFTEST_CALENDAR:-Personal}"
REMINDER_LIST="${SELFTEST_LIST:-Inbox}"
PREFIX="ZZSelfTest"
WRITE=0
[[ "${1:-}" == "--write" ]] && WRITE=1

# Numeric guard: `[[ "$x" -ge 1 ]]` treats a non-numeric $x as a VARIABLE NAME
# and, under `set -u`, aborts the whole run. Tool errors are strings, so every
# numeric comparison has to check the shape first.
isnum(){ [[ "${1:-}" =~ ^[0-9]+$ ]]; }

PASS=0; FAIL=0
green(){ printf '\033[32m  OK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
red(){   printf '\033[31mFAIL\033[0m   %s\n' "$1"; FAIL=$((FAIL+1)); }
info(){  printf '\033[33m  ..\033[0m   %s\n' "$1"; }

# call <tool> <json-args>  -> raw tool text on stdout
call() {
    curl -s -m 120 -X POST "$ENDPOINT" \
        -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}" \
    | python3 -c '
import json,sys
try: d=json.load(sys.stdin)["result"]
except Exception: print("__TRANSPORT_ERROR__"); sys.exit()
text=d["content"][0]["text"]
# Untrusted results arrive fenced in a nonce-delimited envelope. Unlike the
# watcher, this client speaks HTTP to the shared daemon, so it cannot use
# HOMEPORT_RAW -- that is a property of the server process and would
# unwrap every other client too. Strip the fence here instead.
lines=text.split("\n")
if len(lines)>=3 and lines[0].startswith("[UNTRUSTED DATA ") and lines[-1].startswith("[END UNTRUSTED DATA "):
    text="\n".join(lines[1:-1])
print(("__TOOL_ERROR__" if d.get("isError") else "")+text)'
}

# jq-lite: read a python expression against the parsed tool output
q() { python3 -c "
import json,sys
raw=sys.stdin.read()
if raw.startswith('__'): print(raw.strip()); sys.exit()
o=json.loads(raw)
print($1)"; }

cleanup() {
    [[ $WRITE -eq 1 ]] || return 0
    info "cleaning up ${PREFIX} records"
    # Calendar
    ids=$(call calendar_query "{\"start\":\"$(date +%Y-%m-%d)\",\"end\":\"2030-01-01\",\"limit\":2000}" \
        | q "'\n'.join(e['id'] for e in o.get('events',[]) if '$PREFIX' in (e.get('title') or ''))")
    while read -r id; do [[ -n "$id" && "$id" != __* ]] && call calendar_delete_event "{\"id\":\"$id\",\"span\":\"futureEvents\",\"confirmDelete\":true}" >/dev/null; done <<< "$ids"
    # Reminders
    ids=$(call reminders_query '{"status":"all","limit":500}' \
        | q "'\n'.join(r['id'] for r in o.get('reminders',[]) if '$PREFIX' in (r.get('title') or ''))")
    while read -r id; do [[ -n "$id" && "$id" != __* ]] && call reminders_delete "{\"id\":\"$id\",\"confirmDelete\":true}" >/dev/null; done <<< "$ids"
    # Contacts
    ids=$(call contacts_query "{\"search\":\"$PREFIX\",\"limit\":100}" \
        | q "'\n'.join(c['id'] for c in o.get('contacts',[]))")
    while read -r id; do [[ -n "$id" && "$id" != __* ]] && call contacts_delete "{\"id\":\"$id\",\"confirmDelete\":true}" >/dev/null; done <<< "$ids"
}
trap cleanup EXIT

# `tailscale serve` stamps Tailscale-User-Login only on requests that arrive
# from a PEER. A request this node makes to its own serve endpoint carries no
# identity, so the bridge -- correctly -- answers 401 to every one of them, and
# the whole suite fails in a way that looks like a broken deployment. Say so
# once, up front, instead of once per check.
if [[ -n "$SELF_DNS" && "$ENDPOINT" == *"$SELF_DNS"* ]]; then
    cat >&2 <<MSG

This is the bridge host itself ($SELF_DNS).

\`tailscale serve\` only attaches identity headers to requests from OTHER tailnet
nodes, so every authenticated check below would 401 no matter how healthy the
service is. Run this from another enrolled device:

    BRIDGE_ENDPOINT=https://$SELF_DNS/mcp ./pipeline/selftest.sh

To check the service from here instead, use the local health check:

    ./deploy/healthcheck.sh

MSG
    exit 78   # EX_CONFIG
fi

echo
echo "=== transport and identity ==="
# Loopback binding, the direct-loopback 401 and funnel are properties of the
# HOST, and this script runs on a peer. deploy/healthcheck.sh checks them there.

n=$(call reminders_lists '{}' | q "len(o['lists'])")
[[ "$n" =~ ^[0-9]+$ ]] && green "authenticated over HTTPS ($n reminder lists)" \
                       || red "authenticated request failed: $n"

echo
echo "=== all tool families respond ==="
for t in reminders_lists calendar_calendars contacts_groups notes_folders notes_query voicememos_list messages_query contacts_duplicates bridge_ping; do
    out=$(call "$t" '{}')
    [[ "$out" == __* ]] && red "$t -> ${out:0:70}" || green "$t"
done

echo
echo "=== regression guards (these are the bugs we fixed; they must stay fixed) ==="

# Unknown arguments must be rejected, not silently ignored.
out=$(call contacts_query '{"query":"anything"}')
[[ "$out" == __TOOL_ERROR__*Unknown* ]] && green "unknown arguments rejected" \
                                        || red "unknown argument silently accepted"

# Truncation must be visible.
out=$(call messages_query '{"limit":3}' | q "(o['count'],o.get('total'),o.get('truncated'))")
[[ "$out" == *"True"* ]] && green "messages_query reports truncation $out" \
                         || red "messages_query hides truncation: $out"

for pair in "calendar_query:{\"start\":\"2026-01-01\",\"end\":\"2026-12-31\",\"limit\":2}" "reminders_query:{\"limit\":2}"; do
    t="${pair%%:*}"; a="${pair#*:}"
    out=$(call "$t" "$a" | q "('total' in o, 'totalMatched' in o)")
    [[ "$out" == "(True, True)" ]] && green "$t emits total + totalMatched" \
                                   || red "$t missing total keys: $out"
done

# Phone search: the gap that made messages->contacts impossible.
# The fixture is sourced from the address book rather than hardcoded, so this
# file carries nobody's real number.
PHONE=$(call contacts_query '{"limit":40}' | q "next((c['phonesE164'][0] for c in o['contacts'] if c.get('phonesE164')), '')")
if [[ -z "$PHONE" || "$PHONE" == __* ]]; then
    red "could not source a phone fixture from contacts"
else
    out=$(call contacts_query "{\"search\":\"${PHONE: -7}\"}" | q "o['count']")
    isnum "$out" && [[ "$out" -ge 1 ]] && green "contacts_query finds a contact by phone number" \
                                      || red "contacts_query cannot resolve a phone number: $out"
fi

# truncated must be universal, not just on messages/contacts.
for pair in "calendar_query:{\"start\":\"2026-01-01\",\"end\":\"2026-12-31\",\"limit\":1}" "reminders_query:{\"limit\":1}" "messages_query:{\"limit\":1}" "contacts_query:{\"limit\":1}"; do
    t="${pair%%:*}"; a="${pair#*:}"
    out=$(call "$t" "$a" | q "o.get('truncated')")
    [[ "$out" == "True" ]] && green "$t flags truncation" || red "$t truncates silently: $out"
done

# Notes must be readable, not write-only.
out=$(call notes_query '{"limit":1}' | q "o['notes'][0]['id'] if o['notes'] else '__NONE__'")
if [[ "$out" == __* ]]; then
    red "notes_query returned nothing usable: $out"
else
    green "notes_query returns note ids"
    body=$(call notes_read "{\"id\":\"$out\"}" | q "len(o['body'])")
    isnum "$body" && green "notes_read returns a body ($body chars)" \
                  || red "notes_read failed: ${body:0:70}"
fi

# A list whose reminders carry large notes (pasted base64 images, say) can bloat
# a listing by hundreds of KB; listings must be able to opt out.
full=$(call reminders_query '{"limit":500}' | wc -c | tr -d ' ')
trim=$(call reminders_query '{"limit":500,"excludeNotes":true}' | wc -c | tr -d ' ')
isnum "$trim" && isnum "$full" && [[ "$trim" -lt "$full" ]] && green "excludeNotes shrinks payload ($((full/1024))kb -> $((trim/1024))kb)" \
                          || red "excludeNotes did not reduce payload"

# Phone normalization: the step before an irreversible send.
out=$(call contacts_query '{"limit":40}' | q "any(c.get('phonesE164') for c in o['contacts'])")
[[ "$out" == "True" ]] && green "contacts_query emits phonesE164" \
                       || red "contacts_query missing phonesE164: $out"

# notes_query folder scoping: `folders whose name is "X" of acct` parsed the
# `of acct` as part of the string and failed -1723 on every folder.
fold=$(call notes_folders '{}' | q "o['folders'][0]['folder']")
if [[ "$fold" != __* ]]; then
    out=$(call notes_query "{\"folder\":\"$fold\",\"limit\":3}" | q "sorted({n['folder'] for n in o['notes']})")
    [[ "$out" == "['$fold']" ]] && green "notes_query scopes to a folder ($fold)" \
                                || red "notes_query folder scoping broken: $out"
fi
out=$(call notes_query '{"folder":"__nope__","limit":1}')
[[ "$out" == __TOOL_ERROR__*"No folder named"* ]] && green "unknown folder gives a named error" \
                                                  || red "unknown folder did not error cleanly"

# idempotencyKey must be DISCOVERABLE, not just accepted: it was reachable from
# the start but declared in zero schemas, so no client could find it.
out=$(python3 -c "
import json,subprocess
r=subprocess.run(['curl','-s','-m','60','-X','POST','$ENDPOINT','-d',
  '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}'],capture_output=True,text=True)
t=json.loads(r.stdout)['result']['tools']
need=['messages_send','notes_create','notes_append','contacts_merge','contacts_delete',
      'calendar_delete_event','reminders_create','calendar_create_event','voicememos_summarize']
have={x['name'] for x in t if 'idempotencyKey' in x['inputSchema'].get('properties',{})}
print('ok' if all(n in have for n in need) else 'missing: '+str([n for n in need if n not in have]))")
[[ "$out" == "ok" ]] && green "idempotencyKey declared on all mutating tools" \
                     || red "idempotencyKey not discoverable: $out"

# Read-blocked Notes folders: writes allowed, reads denied. Skipped when no
# folder is configured, so this stays valid on a machine without the policy.
BLOCKED=$(python3 -c "
import json,os
p=os.path.expanduser('~/Library/Application Support/homeport/policy.json')
try: print((json.load(open(p)).get('readBlockedNoteFolders') or [''])[0])
except Exception: print('')")
if [[ -n "$BLOCKED" ]]; then
    # Distinguish an ERROR from a LEAK. Reporting a timeout as "the blocked folder leaked"
    # cries wolf, and worse, would let a real leak hide among false alarms.
    res=$(call notes_query '{"limit":60}')
    if [[ "$res" == __* ]]; then
        red "notes_query failed, leak status UNKNOWN: ${res:0:70}"
    else
        out=$(printf '%s' "$res" | q "any(n['folder']=='$BLOCKED' for n in o['notes'])")
        [[ "$out" == "False" ]] && green "unscoped notes_query excludes $BLOCKED" \
                                || red "$BLOCKED LEAKED into an unscoped notes_query"
        out=$(printf '%s' "$res" | q "o.get('suppressed', 0) > 0")
        [[ "$out" == "True" ]] && green "suppression is reported, not silent" \
                               || red "notes withheld with no suppressed count"
    fi

    res=$(call notes_query "{\"folder\":\"$BLOCKED\",\"limit\":5}")
    if [[ "$res" == __* ]]; then
        red "scoped query to $BLOCKED failed, leak status UNKNOWN: ${res:0:70}"
    else
        out=$(printf '%s' "$res" | q "o['count']")
        [[ "$out" == "0" ]] && green "notes_query scoped to $BLOCKED returns nothing" \
                            || red "scoped query to $BLOCKED returned $out notes"
    fi

    out=$(call notes_folders '{}' | q "next((f.get('readable') for f in o['folders'] if f['folder']=='$BLOCKED'), 'absent')")
    [[ "$out" == "False" ]] && green "$BLOCKED still listed, marked readable:false" \
                            || red "$BLOCKED folder marking wrong: $out"

    # The create-then-read pivot: a write returns an id that is a valid read key.
    # It writes a note, so it belongs to --write mode.
    if [[ $WRITE -eq 1 ]]; then
        NEW=$(call notes_create "{\"folder\":\"$BLOCKED\",\"title\":\"${PREFIX} Guard\",\"body\":\"probe\"}" | q "o['created']['id']")
        if [[ "$NEW" == __* ]]; then
            red "write to $BLOCKED failed: ${NEW:0:70}"
        else
            green "write to $BLOCKED still allowed"
            out=$(call notes_read "{\"id\":\"$NEW\"}" | q "('body' in o, o.get('denied'))")
            [[ "$out" == "(False, True)" ]] && green "brand-new $BLOCKED note is immediately unreadable" \
                                            || red "create->read pivot open: $out"
            # There is no notes_delete tool, and this script runs on a peer, not
            # the bridge host, so it cannot remove the probe itself.
            echo "  note: delete '${PREFIX} Guard' from '$BLOCKED' on the bridge host"
        fi
    fi

    # Title-based append must not confirm whether a title exists in the folder.
    out=$(call notes_append "{\"title\":\"zz-nope\",\"html\":\"<p></p>\",\"folder\":\"$BLOCKED\"}")
    [[ "$out" == __TOOL_ERROR__*"read-blocked"* ]] && green "append-by-title into $BLOCKED refused (no title oracle)" \
                                                  || red "append-by-title into $BLOCKED not refused"

    # And the gate must not become a general Notes outage.
    OPEN=$(call notes_folders '{}' | q "next((f['folder'] for f in o['folders'] if f.get('count',0) > 0 and f['folder'] != '$BLOCKED'), '')")
    out=$(call notes_query "{\"folder\":\"$OPEN\",\"limit\":2}" | q "o['count']")
    isnum "$out" && [[ "$out" -ge 1 ]] && green "non-blocked folders read normally" \
                                      || red "non-blocked folder read broke: ${out:0:70}"
fi

# Offset-less ISO must parse.
out=$(call calendar_query '{"start":"2026-09-07T00:00:00","end":"2026-09-08T00:00:00"}')
[[ "$out" == __* ]] && red "offset-less ISO datetime rejected" \
                    || green "offset-less ISO datetime accepted"

if [[ $WRITE -eq 0 ]]; then
    echo
    echo "=== write checks skipped (pass --write to include them) ==="
    echo
    printf 'passed %s, failed %s\n\n' "$PASS" "$FAIL"
    [[ $FAIL -eq 0 ]] || exit 1
    exit 0
fi

echo
echo "=== write paths (scoped to the '$CALENDAR' calendar / '$REMINDER_LIST' list) ==="

# Never fall back to the default calendar: it may be shared.
have=$(call calendar_calendars '{}' | q "sum(1 for c in o['calendars'] if c['title']=='$CALENDAR')")
if [[ "$have" != "1" ]]; then
    red "calendar '$CALENDAR' not found -- refusing to write to the default calendar"
    printf '\npassed %s, failed %s\n\n' "$PASS" "$FAIL"; exit 1
fi
green "target calendar '$CALENDAR' exists"

# Same rule for reminders: reminders_create falls back to the default list.
have=$(call reminders_lists '{}' | q "sum(1 for l in o['lists'] if l['title']=='$REMINDER_LIST')")
if [[ "$have" != "1" ]]; then
    red "reminder list '$REMINDER_LIST' not found -- refusing to write to the default list"
    printf '\npassed %s, failed %s\n\n' "$PASS" "$FAIL"; exit 1
fi
green "target reminder list '$REMINDER_LIST' exists"

START="$(date -v+400d +%Y-%m-%d) 09:00"
EID=$(call calendar_create_event "{\"title\":\"$PREFIX Event\",\"calendar\":\"$CALENDAR\",\"start\":\"$START\",\"end\":\"$(date -v+400d +%Y-%m-%d) 10:00\",\"alarms\":[{\"relativeOffset\":-3600},{\"relativeOffset\":-86400}]}" \
     | q "o['created']['id']")
[[ "$EID" == __* ]] && { red "could not create test event: $EID"; EID=""; } || green "created test event in $CALENDAR"

if [[ -n "$EID" ]]; then
    # It must actually be in Personal, not the default.
    where=$(call calendar_query "{\"start\":\"$(date -v+399d +%Y-%m-%d)\",\"end\":\"$(date -v+401d +%Y-%m-%d)\",\"limit\":200}" \
        | q "next((e.get('calendar') for e in o['events'] if '$PREFIX' in (e.get('title') or '')),'?')")
    [[ "$where" == "$CALENDAR" ]] && green "event landed in '$CALENDAR' (not the default)" \
                                  || red "event landed in '$where', expected '$CALENDAR'"

    # Alarm add must preserve existing alarms.
    out=$(call calendar_update_event "{\"id\":\"$EID\",\"addAlarms\":[{\"relativeOffset\":-600}]}" \
        | q "sorted(a['relativeOffset'] for a in o['updated'].get('alarms',[]))")
    [[ "$out" == "[-86400, -3600, -600]" ]] && green "addAlarms preserved existing alarms" \
                                            || red "addAlarms lost alarms: $out"

    # Adding a duplicate must be a no-op.
    out=$(call calendar_update_event "{\"id\":\"$EID\",\"addAlarms\":[{\"relativeOffset\":-600}]}" \
        | q "len(o['updated'].get('alarms',[]))")
    [[ "$out" == "3" ]] && green "duplicate alarm not re-added" || red "duplicate alarm added: count=$out"

    # setAlarms without confirmation must be refused.
    out=$(call calendar_update_event "{\"id\":\"$EID\",\"setAlarms\":[{\"relativeOffset\":-60}]}")
    [[ "$out" == __TOOL_ERROR__* ]] && green "setAlarms blocked without confirmReplace" \
                                    || red "setAlarms replaced alarms without confirmation"

    # Delete must preview, not delete.
    out=$(call calendar_delete_event "{\"id\":\"$EID\"}" | q "o['deleted']")
    [[ "$out" == "False" ]] && green "calendar_delete_event previews without confirmDelete" \
                            || red "calendar_delete_event deleted without confirmation"
fi

RID=$(call reminders_create "{\"title\":\"$PREFIX Reminder\",\"list\":\"$REMINDER_LIST\"}" | q "o['created']['id']")
[[ "$RID" == __* ]] && { red "could not create test reminder: $RID"; RID=""; } || green "created test reminder in $REMINDER_LIST"
if [[ -n "$RID" ]]; then
    out=$(call reminders_delete "{\"id\":\"$RID\"}" | q "o['deleted']")
    [[ "$out" == "False" ]] && green "reminders_delete previews without confirmDelete" \
                            || red "reminders_delete deleted without confirmation"
fi

CID=$(call contacts_create "{\"givenName\":\"$PREFIX\",\"familyName\":\"Probe\",\"phones\":[{\"label\":\"mobile\",\"value\":\"+15550007777\"}]}" | q "o['created']['id']")
[[ "$CID" == __* ]] && { red "could not create test contact: $CID"; CID=""; } || green "created test contact"
if [[ -n "$CID" ]]; then
    # Regression: create must not drop phone numbers.
    out=$(call contacts_query "{\"search\":\"5550007777\"}" | q "o['count']")
    [[ "$out" == "1" ]] && green "contacts_create kept the phone number (findable by it)" \
                        || red "contacts_create dropped phones, or phone search broke: count=$out"

    out=$(call contacts_update "{\"id\":\"$CID\",\"addPhones\":[{\"label\":\"work\",\"value\":\"+15550008888\"}],\"confirmReplace\":true}" \
        | q "len(o['updated'].get('phones',[]))")
    [[ "$out" == "2" ]] && green "addPhones preserved the existing number" \
                        || red "addPhones destroyed existing numbers: count=$out"

    out=$(call contacts_update "{\"id\":\"$CID\",\"setPhones\":[{\"label\":\"mobile\",\"value\":\"+15550009999\"}]}")
    [[ "$out" == __TOOL_ERROR__* ]] && green "setPhones blocked without confirmReplace" \
                                    || red "setPhones replaced numbers without confirmation"

    out=$(call contacts_delete "{\"id\":\"$CID\"}" | q "o['deleted']")
    [[ "$out" == "False" ]] && green "contacts_delete previews without confirmDelete" \
                            || red "contacts_delete deleted without confirmation"
fi

echo
printf 'passed %s, failed %s\n\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
