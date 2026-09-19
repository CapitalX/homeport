#!/usr/bin/env bash
#
# Pre-publication privacy sweep. See CLAUDE.md § "Pre-publication sweep".
#
#   ./scripts/privacy-sweep.sh
#
# Three checks, each of which has caught something real in this repo's history:
#
#   1. Identifiers: home paths, real tailnet hosts and addresses, email
#      addresses, phone numbers and certificate hashes, outside a small
#      allowlist of documentation placeholders.
#   2. Git metadata: every author, committer and tagger email must be a GitHub
#      noreply address. With no user.email set, git fabricates one from the
#      hostname -- a stable device identifier in every commit.
#   3. Vocabulary: words that would characterise the maintainer -- list and
#      calendar names, routines, employer, places. The list is PRIVATE by
#      nature (publishing it would disclose exactly what it protects), so it is
#      never in the repo: CI reads it from the SWEEP_DENYLIST secret, and a
#      local run from ~/.config/homeport/sweep-denylist.txt. One term per line,
#      matched as a whole word, case-insensitively. No list means the check is
#      skipped with a notice, not failed, so forks still get checks 1 and 2.
#
# Findings print as file:line only. The matching text is never echoed, so a
# vocabulary hit does not end up in a public CI log.
#
# Also usable as a git pre-push hook:
#   ln -s ../../scripts/privacy-sweep.sh .git/hooks/pre-push
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || { echo "not inside the repository" >&2; exit 2; }

FAIL=0
fail() { printf '\033[31mFAIL\033[0m  %s\n' "$1"; FAIL=1; }
ok()   { printf '\033[32m  OK\033[0m  %s\n' "$1"; }
indent() { while IFS= read -r line; do printf '        %s\n' "$line"; done <<< "$1"; }

# Tracked files only, so build output and untracked scratch never count.
FILES=()
while IFS= read -r -d '' f; do FILES+=("$f"); done < <(git ls-files -z)

# Report file:line for every line matching $1 (ERE) and not matching the
# allowlist $2 (ERE, may be empty). Prints nothing when clean.
scan() {
    local allow="${2:-}"
    grep -nIE -- "$1" "${FILES[@]}" 2>/dev/null \
        | { if [[ -n "$allow" ]]; then grep -vE -- "$allow"; else cat; fi; } \
        | cut -d: -f1,2
}

# check LABEL PATTERN [ALLOWLIST]
check() {
    local hits
    hits="$(scan "$2" "${3:-}")"
    if [[ -z "$hits" ]]; then ok "$1"; else fail "$1:"; indent "$hits"; fi
}

echo "== identifiers"
check "no absolute home paths" \
    '/(Users|home)/[A-Za-z0-9._-]+'
check "no real tailnet hostnames" \
    '[A-Za-z0-9-]+\.[A-Za-z0-9-]+\.ts\.net'
check "no tailnet addresses beyond the documentation placeholders" \
    '\b100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b' \
    '100\.64\.0\.[0-9]+|100\.100\.100\.[0-9]+|100\.99\.99\.99'
check "no email addresses beyond example domains and noreply" \
    '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
    '@(example\.(com|org|net)|evil\.com|users\.noreply\.github\.com|anthropic\.com)'
check "no phone numbers outside the 555 range" \
    '(\+?1[ .-]?)?\(?[2-9][0-9]{2}\)?[ .-][0-9]{3}[ .-][0-9]{4}\b' \
    '555'
check "no certificate hashes" \
    '\b[0-9A-Fa-f]{40}\b'

echo "== git metadata"
bad="$( { git log --all --format='%ae%n%ce'
          git for-each-ref refs/tags --format='%(taggeremail)' | tr -d '<>'; } \
        | grep -v '^$' | sort -u \
        | grep -vE '@users\.noreply\.github\.com$|^noreply@github\.com$' )"
if [[ -z "$bad" ]]; then
    ok "every author, committer and tagger email is a GitHub noreply address"
else
    # Emails are identifiers, but these are already public in the pushed
    # history this check is reading; naming them is what makes them fixable.
    fail "non-noreply identities in history:"; indent "$bad"
fi

echo "== vocabulary"
LIST=""
if [[ -n "${SWEEP_DENYLIST:-}" ]]; then
    LIST="$SWEEP_DENYLIST"
elif [[ -r "$HOME/.config/homeport/sweep-denylist.txt" ]]; then
    LIST="$(cat "$HOME/.config/homeport/sweep-denylist.txt")"
fi
LIST="$(grep -v '^[[:space:]]*\(#.*\)\{0,1\}$' <<< "$LIST" || true)"
if [[ -z "$LIST" ]]; then
    echo "  --   skipped: no denylist (set SWEEP_DENYLIST or ~/.config/homeport/sweep-denylist.txt)"
    [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::notice::vocabulary sweep skipped: no SWEEP_DENYLIST secret available"
else
    hits="$(grep -nIiwF -f <(printf '%s\n' "$LIST") -- "${FILES[@]}" 2>/dev/null | cut -d: -f1,2)"
    n="$(grep -c . <<< "$LIST")"
    if [[ -z "$hits" ]]; then ok "no denylisted vocabulary ($n terms)"
    else fail "denylisted vocabulary (text withheld; inspect locally):"; indent "$hits"; fi
fi

echo
if [[ $FAIL -eq 0 ]]; then echo "privacy sweep: clean"; else echo "privacy sweep: FAILED"; fi
exit $FAIL
