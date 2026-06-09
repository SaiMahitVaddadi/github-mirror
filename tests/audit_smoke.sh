#!/usr/bin/env bash
# Audit smoke test: builds a tmp tree of fake .git repos, runs `mirror
# audit` against it, and verifies classification. NEVER calls --apply
# (would hit the live GitHub API).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/mirror"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }

# 1. Stand up an isolated XDG_CONFIG_HOME with a fake mirror config so
#    `mirror audit` knows what counts as "ours".
TMP_XDG=$(mktemp -d)
TMP_STATE=$(mktemp -d)
TMP_REPOS=$(mktemp -d)
trap 'rm -rf "$TMP_XDG" "$TMP_STATE" "$TMP_REPOS"' EXIT

PRIMARY="primary-acct"
MIRROR="mirror-acct"

mkdir -p "$TMP_XDG/github-mirror"
cat > "$TMP_XDG/github-mirror/config.json" <<JSON
{
  "primary": "$PRIMARY",
  "mirror":  "$MIRROR",
  "accounts": ["$PRIMARY", "$MIRROR"],
  "default_visibility": "private",
  "reconcile_interval_min": 60,
  "ignore": []
}
JSON

# 2. Build four fake repos:
#    ours     → origin = github.com/$PRIMARY/foo
#    external → origin = github.com/strangers/bar
#    other    → origin = gitlab.com/whoever/baz
#    none     → no origin remote
mk_repo() {
  local dir="$1" url="${2:-}"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name  "test"
  [[ -n "$url" ]] && git -C "$dir" remote add origin "$url"
}

mk_repo "$TMP_REPOS/ours-repo"     "https://github.com/$PRIMARY/ours-repo.git"
mk_repo "$TMP_REPOS/external-repo" "https://github.com/strangers/external-repo.git"
mk_repo "$TMP_REPOS/other-repo"    "https://gitlab.com/whoever/other-repo.git"
mk_repo "$TMP_REPOS/orphan-repo"   ""

# 3. Run audit. stdout = the classification table, stderr = the summary.
out=$(XDG_CONFIG_HOME="$TMP_XDG" XDG_STATE_HOME="$TMP_STATE" \
      "$BIN" audit "$TMP_REPOS" 2>/dev/null) \
  || fail "mirror audit exited non-zero"

# Verify each row has the right STATUS column.
grep -q $'^ours\t' <<<"$out" || fail "no 'ours' row in:\n$out"
grep -q $'^external\t' <<<"$out" || fail "no 'external' row in:\n$out"
grep -q $'^other\t' <<<"$out" || fail "no 'other' row in:\n$out"
grep -q $'^none\t' <<<"$out" || fail "no 'none' row in:\n$out"
pass "audit classifies ours/external/other/none"

# 4. Specifically the row for ours-repo should show $PRIMARY in the acct column.
ours_row=$(grep $'^ours\t' <<<"$out")
[[ "$ours_row" == *"$PRIMARY"* ]] || fail "ours row missing primary acct: $ours_row"
[[ "$ours_row" == *"ours-repo"* ]] || fail "ours row missing repo path: $ours_row"
pass "ours row carries primary acct"

# 5. --ignore should suppress matched paths.
out2=$(XDG_CONFIG_HOME="$TMP_XDG" XDG_STATE_HOME="$TMP_STATE" \
       "$BIN" audit --ignore "$TMP_REPOS/external-repo" "$TMP_REPOS" 2>/dev/null) \
  || fail "mirror audit --ignore exited non-zero"
if grep -q "external-repo" <<<"$out2"; then
  fail "--ignore did not exclude external-repo:\n$out2"
fi
pass "--ignore suppresses match"

# 6. Summary lines on stderr.
summary=$(XDG_CONFIG_HOME="$TMP_XDG" XDG_STATE_HOME="$TMP_STATE" \
          "$BIN" audit "$TMP_REPOS" 2>&1 >/dev/null)
[[ "$summary" == *"total:     4"*    ]] || fail "wrong total: $summary"
[[ "$summary" == *"ours:      1"*    ]] || fail "wrong ours: $summary"
[[ "$summary" == *"external:  1"*    ]] || fail "wrong external: $summary"
[[ "$summary" == *"other:     1"*    ]] || fail "wrong other: $summary"
[[ "$summary" == *"no origin: 1"*    ]] || fail "wrong none: $summary"
pass "summary tallies match"

# 7. Missing path is reported, not fatal.
missing_out=$(XDG_CONFIG_HOME="$TMP_XDG" XDG_STATE_HOME="$TMP_STATE" \
              "$BIN" audit "$TMP_REPOS" "/no/such/path/xyzzy" 2>&1 >/dev/null) \
  || fail "audit should tolerate one missing path when another is real"
[[ "$missing_out" == *"skipping missing path"* ]] || fail "no warning for missing path"
pass "missing paths warn but don't fail"

# 8. --apply --dry-run never invokes the API and never crashes.
#    Stub `gh` so a stray live call would fail the test loudly.
PATH_STUB=$(mktemp -d)
cat > "$PATH_STUB/gh" <<'STUB'
#!/usr/bin/env bash
echo "FAIL: gh was called during --dry-run: $*" >&2
exit 99
STUB
chmod +x "$PATH_STUB/gh"
dry_out=$(PATH="$PATH_STUB:$PATH" XDG_CONFIG_HOME="$TMP_XDG" \
          XDG_STATE_HOME="$TMP_STATE" "$BIN" audit --apply --dry-run \
          "$TMP_REPOS" 2>&1 >/dev/null) \
  || fail "audit --apply --dry-run exited non-zero (gh stub may have fired): $dry_out"
[[ "$dry_out" == *"apply: 3 repos to claim"* ]] || fail "apply queue wrong: $dry_out"
pass "--apply --dry-run queues 3 (external + other + none) without calling gh"

# 9. _sanitize_repo_name handles edge cases. Source the lib in a child
#    shell so we don't trip the parent's lack of set -e config.
CONFIG_FILE=/dev/null STATE_DIR="$TMP_STATE" LOG_FILE="$TMP_STATE/mirror.log" \
  source "$ROOT/lib/_common.sh"
[[ "$(_sanitize_repo_name 'aizynthfinder')"     == 'aizynthfinder' ]]     || fail "plain name sanitization"
[[ "$(_sanitize_repo_name 'repo.config')"       == 'repo.config' ]]       || fail "dot-in-middle preserved"
[[ "$(_sanitize_repo_name '.github')"           == 'github' ]]            || fail "leading dot stripped"
[[ "$(_sanitize_repo_name '.config')"           == 'config' ]]            || fail "leading dot stripped (.config)"
[[ "$(_sanitize_repo_name 'weird name w/ spaces')" == 'weird-name-w-spaces' ]] || fail "space/slash collapsed"
[[ "$(_sanitize_repo_name '..')"                == '' ]]                  || fail "'..' rejected"
[[ "$(_sanitize_repo_name '___')"               == '' ]]                  || fail "all-underscores rejected"
[[ "$(_sanitize_repo_name '-leading-dash')"     == 'leading-dash' ]]      || fail "leading dash stripped"
[[ "$(_sanitize_repo_name 'trailing-')"         == 'trailing' ]]          || fail "trailing dash stripped"
pass "_sanitize_repo_name edge cases"

# 10. _redact_token strips the token from a sample push-error message.
sample="remote: error\nfatal: https://x-access-token:ghp_ABC123@github.com/x/y"
red=$(printf '%s' "$sample" | _redact_token "ghp_ABC123")
[[ "$red" == *"***"* ]]      || fail "redact: no replacement: $red"
[[ "$red" != *"ghp_ABC123"* ]] || fail "redact: token leaked: $red"
red_empty=$(printf 'hello' | _redact_token "")
[[ "$red_empty" == 'hello' ]] || fail "empty-token redact corrupted input: $red_empty"
pass "_redact_token strips token and tolerates empty"

echo "all audit smoke checks passed"
