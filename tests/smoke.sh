#!/usr/bin/env bash
# Smoke test: lints, helps, dry-run paths. Doesn't hit GitHub.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/mirror"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }

# 1. The script must be executable.
[[ -x "$BIN" ]] || fail "$BIN is not executable"
pass "executable bit set"

# 2. bash -n parses cleanly.
bash -n "$BIN" || fail "bash -n rejected bin/mirror"
bash -n "$ROOT/lib/_common.sh" || fail "bash -n rejected lib/_common.sh"
bash -n "$ROOT/install.sh" || fail "bash -n rejected install.sh"
pass "bash syntax check"

# 3. shellcheck if available.
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "$BIN" "$ROOT/lib/_common.sh" "$ROOT/install.sh" || fail "shellcheck warnings"
  pass "shellcheck clean"
else
  echo "skip shellcheck (not installed)"
fi

# 4. help command runs without config.
"$BIN" help >/dev/null || fail "help command exited non-zero"
pass "help runs"

# 5. status command without config should die with a clear message.
# Use an isolated XDG_CONFIG_HOME so this test doesn't depend on whether
# the user has already run `mirror init` in their real home.
TMP_XDG=$(mktemp -d)
if XDG_CONFIG_HOME="$TMP_XDG" "$BIN" status 2>/dev/null; then
  rm -rf "$TMP_XDG"
  fail "status should refuse to run without config"
fi
rm -rf "$TMP_XDG"
pass "status fails closed without config"

# 6. URL parser handles common forms.
# shellcheck source=../lib/_common.sh
CONFIG_FILE=/dev/null STATE_DIR=/tmp LOG_FILE=/tmp/mirror-smoke.log \
  source "$ROOT/lib/_common.sh"
o=""; n=""
parse_github_url "https://github.com/alice/repo.git" o n
[[ "$o" == "alice" && "$n" == "repo" ]] || fail "https parse: got '$o/$n'"
parse_github_url "git@github.com:alice/repo.git" o n
[[ "$o" == "alice" && "$n" == "repo" ]] || fail "ssh parse: got '$o/$n'"
parse_github_url "https://github.com/alice/repo" o n
[[ "$o" == "alice" && "$n" == "repo" ]] || fail "no-suffix parse: got '$o/$n'"
parse_github_url "https://example.com/alice/repo.git" o n
[[ -z "$o" && -z "$n" ]] || fail "non-github URL should yield empty"
# Dot in repo name (GitHub allows it: dotfiles.io, repo.config, etc.).
parse_github_url "https://github.com/alice/repo.io" o n
[[ "$o" == "alice" && "$n" == "repo.io" ]] || fail "dot-name parse: got '$o/$n'"
parse_github_url "git@github.com:alice/my.cool.repo.git" o n
[[ "$o" == "alice" && "$n" == "my.cool.repo" ]] || fail "ssh-with-dots parse: got '$o/$n'"
pass "parse_github_url"

echo "all smoke checks passed"

# 7. Run the audit smoke suite if present (lives in its own file so it can
#    stand up an isolated XDG_CONFIG_HOME + fake .git tree without
#    interfering with the assertions above).
if [[ -x "$ROOT/tests/audit_smoke.sh" ]]; then
  echo
  bash "$ROOT/tests/audit_smoke.sh" || fail "audit_smoke.sh failed"
fi
