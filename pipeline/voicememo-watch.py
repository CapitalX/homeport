#!/usr/bin/env python3
"""
Watches the Voice Memos library and files new recordings automatically.

Design notes
------------
This script deliberately never touches the Voice Memos directory itself. That
path is protected by Full Disk Access, and the bridge binary already holds that
grant (its disclaim shim makes it its own TCC-responsible process). So the
watcher only ever speaks JSON-RPC to the bridge and needs no permissions of its
own -- which is also why it can run from launchd, where TCC prompts could never
appear.

Routing follows the rule the bridge enforces in code:

  categorized    summarized on the LOCAL model and filed to Notes. Whether the
                 text may also be returned to a caller is declared per category
                 in categories.json and enforced inside the bridge, not here.
  uncategorized  transcribed on-device for searchability. Nothing filed,
                 nothing synced, nothing guessed at.

Stability: a recording is only processed on the SECOND scan that sees it. iCloud
delivers large files progressively, and transcribing a half-synced file yields a
silently truncated transcript. Waiting one interval costs nothing and avoids it.
"""

import json
import os
import subprocess
import sys
import time
from datetime import datetime

HOME = os.path.expanduser("~")
# Where the signed bridge lives. pipeline/install.sh writes HOMEPORT_BIN into
# the LaunchAgent from wherever the checkout is; the fallback covers running
# this script by hand from inside the repo.
_BIN_CANDIDATES = [
    os.environ.get("HOMEPORT_BIN", ""),
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                 "bin/Homeport.app/Contents/MacOS/Homeport"),
]
BRIDGE = next((p for p in _BIN_CANDIDATES if p and os.path.exists(p)), _BIN_CANDIDATES[-1])

SUPPORT = os.path.join(HOME, "Library/Application Support/homeport")
STATE_PATH = os.path.join(SUPPORT, "watch-state.json")
LOG_PATH = os.path.join(HOME, "Library/Logs/voicememo-watch.log")

MAX_ATTEMPTS = 3


def log(message):
    line = f"{datetime.now():%Y-%m-%d %H:%M:%S}  {message}"
    print(line, flush=True)
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, "a") as handle:
            handle.write(line + "\n")
    except OSError:
        pass


# --- bridge -----------------------------------------------------------------

def bridge_call(tool, arguments, timeout=3600):
    """One tool call. The bridge is stdio, so each call is its own process."""
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": "2025-06-18", "capabilities": {}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": tool, "arguments": arguments}},
    ]
    payload = "".join(json.dumps(r) + "\n" for r in requests)
    # Ask for unwrapped output. Tool results are normally fenced in an
    # untrusted-content envelope so a model can tell data from instructions;
    # that envelope is not valid JSON, and the json.loads below fails SOFT --
    # it would return {"text": ...} and this script would file records with a
    # null title, silently. An env var rather than a tool argument because a
    # subprocess owns its environment and a language model cannot set one.
    env = {**os.environ, "HOMEPORT_RAW": "1"}
    try:
        proc = subprocess.run([BRIDGE], input=payload, capture_output=True,
                              text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"{tool} timed out after {timeout}s")

    messages = []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                messages.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    if not messages:
        raise RuntimeError(f"{tool} returned nothing (stderr: {proc.stderr[:200]})")

    result = messages[-1].get("result", {})
    text = (result.get("content") or [{}])[0].get("text", "")
    if result.get("isError"):
        raise RuntimeError(text.strip() or f"{tool} failed")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return {"text": text}


# --- state ------------------------------------------------------------------

def load_state():
    try:
        with open(STATE_PATH) as handle:
            state = json.load(handle)
    except (OSError, json.JSONDecodeError):
        state = {}
    state.setdefault("seen", {})       # id -> first-seen ISO timestamp
    state.setdefault("processed", {})  # id -> outcome record
    state.setdefault("attempts", {})   # id -> failure count
    return state


def save_state(state):
    os.makedirs(SUPPORT, exist_ok=True)
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w") as handle:
        json.dump(state, handle, indent=2)
    os.replace(tmp, STATE_PATH)        # atomic: a killed run cannot corrupt state


# --- handling --------------------------------------------------------------

def handle_categorized(record, category):
    """Summarize with the LOCAL model and file the result.

    There is deliberately no per-category branch here. What a category means --
    where it files, whether its action items become reminders, and above all
    whether its text may be returned to a caller -- is declared in
    categories.json and enforced inside the bridge. Encoding any of that here
    would put the privacy rule in two places, and the copy that drifts is the
    one that leaks.
    """
    result = bridge_call("voicememos_summarize",
                         {"id": record["id"], "deliver": "note", "category": category})
    outcome = {
        "action": "summarized-local",
        "category": category,
        "title": result.get("title"),
        "note": (result.get("note") or {}).get("id"),
        "reminders": result.get("remindersCreated", 0),
    }
    if result.get("remindersWarning"):
        outcome["warning"] = result["remindersWarning"]
    return outcome


def handle_uncategorized(record):
    """Transcribe for searchability and stop.

    A recording we could not identify gets no summary and is filed nowhere. The
    conservative branch is the default on purpose: acting on a guess is how a
    private recording ends up somewhere it should not be.
    """
    result = bridge_call("voicememos_transcribe", {"id": record["id"]})
    return {"action": "transcribed-only", "words": result.get("wordCount", 0)}


# --- main -------------------------------------------------------------------

def seed(state, recordings, now):
    """Mark the newest 50 existing recordings as handled, without doing any work.

    Run once when first enabling the watcher: otherwise its first real pass
    would treat the entire back catalogue as new and re-summarize all of it.
    """
    added = 0
    for record in recordings:
        if record["id"] in state["processed"]:
            continue
        state["processed"][record["id"]] = {
            "action": "seeded-preexisting",
            "category": (record.get("classification") or {}).get("category", "unknown"),
            "at": now,
        }
        state["seen"].setdefault(record["id"], now)
        added += 1
    save_state(state)
    log(f"SEED marked {added} pre-existing recording(s) as handled")
    return 0


def main():
    state = load_state()
    try:
        listing = bridge_call("voicememos_list", {"limit": 50}, timeout=1800)
    except RuntimeError as error:
        log(f"ERROR listing recordings: {error}")
        return 1

    recordings = listing.get("recordings", [])
    now = datetime.now().isoformat(timespec="seconds")

    if "--seed" in sys.argv:
        return seed(state, recordings, now)

    # Transcribe BEFORE deciding anything.
    #
    # Mac-recorded .m4a files carry no transcript, so without one only the
    # configured time-window rules can apply, and a recording outside every
    # window gets a low-confidence guess that the transcript would settle
    # instantly. Transcribing first is cached, and it is what makes the
    # category trustworthy.
    warmed = False
    for record in recordings:
        rid = record["id"]
        if rid in state["processed"] or rid not in state["seen"]:
            continue
        if state["attempts"].get(rid, 0) >= MAX_ATTEMPTS:
            continue
        if (record.get("classification") or {}).get("contentCategory"):
            continue
        log(f"WARM {record['file']} — transcribing before classifying")
        try:
            bridge_call("voicememos_transcribe", {"id": rid})
            warmed = True
        except RuntimeError as error:
            log(f"     transcribe failed: {error}")

    if warmed:
        # Re-read so decisions below use the transcript-backed category.
        try:
            recordings = bridge_call("voicememos_list", {"limit": 50},
                                     timeout=1800).get("recordings", [])
        except RuntimeError as error:
            log(f"ERROR re-listing after transcription: {error}")
            return 1

    fresh = 0

    for record in recordings:
        rid = record["id"]
        if rid in state["processed"]:
            continue
        if state["attempts"].get(rid, 0) >= MAX_ATTEMPTS:
            continue
        if rid not in state["seen"]:
            # First sighting: let iCloud finish delivering before we read it.
            state["seen"][rid] = now
            log(f"NEW  {record['file']} — waiting one interval to settle")
            fresh += 1
            continue

        classification = record.get("classification") or {}
        category = classification.get("category", "unknown")

        if classification.get("needsAdjudication"):
            log(f"HOLD {record['file']} — category {category} "
                f"(conf {classification.get('confidence')}) needs review; transcribing only")
            try:
                handle_uncategorized(record)
            except RuntimeError as error:
                log(f"     transcribe failed: {error}")
            state["processed"][rid] = {"action": "held-for-review", "category": category,
                                       "at": now}
            save_state(state)
            continue

        known = category not in ("", "unknown")

        log(f"PROC {record['file']} — {category} ({record.get('durationMinutes')} min)")
        started = time.time()
        try:
            outcome = (handle_categorized(record, category) if known
                       else handle_uncategorized(record))
        except RuntimeError as error:
            state["attempts"][rid] = state["attempts"].get(rid, 0) + 1
            log(f"FAIL {record['file']} — {error} "
                f"(attempt {state['attempts'][rid]}/{MAX_ATTEMPTS})")
            save_state(state)
            continue
        outcome.update({"category": category, "at": now,
                        "seconds": round(time.time() - started)})
        state["processed"][rid] = outcome
        save_state(state)
        log(f"DONE {record['file']} — {outcome}")

    if fresh:
        save_state(state)
    return 0


if __name__ == "__main__":
    sys.exit(main())
