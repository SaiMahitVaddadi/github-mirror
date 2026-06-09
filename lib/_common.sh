#!/usr/bin/env bash
# Shared helpers for github-mirror. Sourced by bin/mirror — assumes the
# caller has set CONFIG_FILE, STATE_DIR, LOG_FILE.

# ── basics ───────────────────────────────────────────────────────────────────
log() {
  local ts msg
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  msg="[$ts] $*"
  echo "$msg" >&2
  if [[ -n "${LOG_FILE:-}" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$msg" >> "$LOG_FILE"
  fi
}

die() { log "ERROR: $*"; exit 1; }

require_cmd() {
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  (( ${#missing[@]} == 0 )) || die "missing required commands: ${missing[*]}"
}

# ── config ───────────────────────────────────────────────────────────────────
load_config() {
  [[ -f "$CONFIG_FILE" ]] || die "no config — run 'mirror init' first"
  PRIMARY=$(jq -r '.primary' "$CONFIG_FILE")
  MIRROR=$(jq -r '.mirror'  "$CONFIG_FILE")
  DEFAULT_VIS=$(jq -r '.default_visibility // "private"' "$CONFIG_FILE")
  [[ -n "$PRIMARY" && -n "$MIRROR" && "$PRIMARY" != "$MIRROR" ]] \
    || die "config invalid — primary/mirror must be two distinct accounts"
}

is_ignored() {
  local name="$1"
  jq -e --arg n "$name" '.ignore | index($n)' "$CONFIG_FILE" >/dev/null 2>&1
}

# ── gh wrappers ──────────────────────────────────────────────────────────────
# Run a gh command as a specific account by injecting that account's token
# for the duration of the call. No global state, no `gh auth switch`, so
# parallel `gh` use in another terminal isn't disturbed and a Ctrl-C can't
# leave the user logged in as the wrong account.
#
# Requires `gh auth login` previously for `$acct` — the token comes from
# `gh auth token --user`. If that fails we surface the error loudly.
gh_with_account() {
  local acct="$1"; shift
  local token
  token=$(gh auth token --user "$acct" 2>/dev/null) \
    || die "no stored gh token for account '$acct' — run 'gh auth login' first"
  GH_TOKEN="$token" GITHUB_TOKEN="$token" gh "$@"
}

gh_list_repos() {
  local acct="$1"
  # --no-archived is a server-side filter, so we don't pay wire bytes for
  # archived repos. Limit 1000 covers ~all personal accounts; if more,
  # gh paginates internally when --paginate is set.
  local raw
  raw=$(gh_with_account "$acct" repo list "$acct" \
        --limit 1000 --no-archived \
        --json name,visibility,pushedAt,isArchived,isFork,defaultBranchRef,nameWithOwner)
  if [[ "$(jq 'length' <<<"$raw")" -ge 1000 ]]; then
    log "WARN: $acct returned >=1000 repos — page boundary; consider raising the limit in gh_list_repos"
  fi
  jq '.' <<<"$raw"
}

gh_repo_exists() {
  local acct="$1" name="$2"
  gh_with_account "$acct" api -X GET "repos/$acct/$name" >/dev/null 2>&1
}

gh_repo_visibility() {
  local acct="$1" name="$2"
  gh_with_account "$acct" api -X GET "repos/$acct/$name" \
    --jq '.visibility // (if .private then "private" else "public" end)' 2>/dev/null || echo ""
}

gh_create_repo() {
  local acct="$1" name="$2" visibility="$3" desc="$4"
  if gh_repo_exists "$acct" "$name"; then
    log "$acct/$name already exists — skipping create"
    return 0
  fi
  local flags=()
  case "$visibility" in
    public)   flags+=(--public) ;;
    private)  flags+=(--private) ;;
    internal) flags+=(--internal) ;;
    *)        flags+=(--private) ;;
  esac
  [[ -n "$desc" ]] && flags+=(--description "$desc")
  log "creating $acct/$name ($visibility)"
  gh_with_account "$acct" repo create "$acct/$name" "${flags[@]}" >/dev/null
}

# ── git URL parsing ──────────────────────────────────────────────────────────
# Writes owner + name to the variables named by $2, $3 in the CALLER's scope.
#
# Locals inside this function are prefixed `_pgu_` so they cannot shadow a
# caller variable also called `owner` or `name`. bash's dynamic scoping
# means `printf -v "owner"` walks up the scope chain looking for a local
# named `owner`; if this function had its own `local owner` it would
# capture the write and the caller would never see it.
parse_github_url() {
  local _pgu_url="$1" _pgu_dst_owner="$2" _pgu_dst_name="$3"
  local _pgu_owner="" _pgu_name=""
  if [[ "$_pgu_url" =~ github\.com[:/]+([^/]+)/(.+)$ ]]; then
    _pgu_owner="${BASH_REMATCH[1]}"
    _pgu_name="${BASH_REMATCH[2]}"
    _pgu_name="${_pgu_name%/}"
    _pgu_name="${_pgu_name%.git}"
  fi
  printf -v "$_pgu_dst_owner" '%s' "$_pgu_owner"
  printf -v "$_pgu_dst_name"  '%s' "$_pgu_name"
}

# ── fan-out remote ───────────────────────────────────────────────────────────
# Wire 'origin' so:
#   fetch URL  = primary
#   push URLs  = primary AND mirror
#
# Idempotent: running it again replaces existing push URLs cleanly.
setup_fanout_remote() {
  local primary_owner="$1" mirror_owner="$2" name="$3"
  local primary_url="https://github.com/$primary_owner/$name.git"
  local mirror_url="https://github.com/$mirror_owner/$name.git"

  if ! git remote get-url origin >/dev/null 2>&1; then
    git remote add origin "$primary_url"
  else
    git remote set-url origin "$primary_url"
  fi

  # Reset push URLs by clearing every existing one and re-adding both.
  # `git remote set-url --delete --push` removes by regex; '.' matches all.
  git remote set-url --delete --push origin '.*' 2>/dev/null || true
  git remote set-url --add --push origin "$primary_url"
  git remote set-url --add --push origin "$mirror_url"

  log "origin fan-out: → $primary_url  → $mirror_url"
}

# ── reconcile ─────────────────────────────────────────────────────────────────
# Repo on `src` but missing on `dst` → create on dst, push every branch + tag.
# Runs in a subshell so the tmpdir cleanup trap doesn't leak to the caller.
reconcile_one() (
  local src="$1" dst="$2" name="$3" force="$4"

  log "reconcile_one src=$src dst=$dst name=$name force=$force"

  # Match the source repo's visibility instead of forcing $DEFAULT_VIS — a
  # public repo on primary should be public on mirror too.
  local vis
  vis=$(gh_repo_visibility "$src" "$name")
  vis="${vis:-$DEFAULT_VIS}"
  gh_create_repo "$dst" "$name" "$vis" "mirror of github.com/$src/$name"

  local tmp
  tmp=$(mktemp -d -t mirror-reconcile.XXXXXX)
  trap "rm -rf '$tmp'" EXIT

  # `--mirror` clone gives a bare repo with every ref. Pushing --mirror back
  # writes every ref, including deletions — that's why we gate it behind
  # `force` for the *common-repo* branch but here the dst repo is fresh.
  gh_with_account "$src" repo clone "$src/$name" "$tmp/repo" -- --mirror --quiet
  git -C "$tmp/repo" remote set-url origin "https://github.com/$dst/$name.git"
  GIT_TERMINAL_PROMPT=0 git -C "$tmp/repo" push --mirror "https://github.com/$dst/$name.git"
  log "reconciled $src/$name → $dst/$name"
)

# When both sides have the repo, compare default-branch tip SHAs via the API.
# If equal, no work. If different, only --mirror push when --force is set.
# Subshell so the tmpdir trap doesn't leak.
sync_common() (
  local name="$1" force="$2" dry="$3"

  local p_sha m_sha p_branch m_branch
  p_branch=$(gh_with_account "$PRIMARY" api -X GET "repos/$PRIMARY/$name" 2>/dev/null | jq -r '.default_branch // ""')
  m_branch=$(gh_with_account "$MIRROR" api -X GET "repos/$MIRROR/$name" 2>/dev/null | jq -r '.default_branch // ""')
  [[ -n "$p_branch" && -n "$m_branch" ]] || { log "skip $name (no default branch reported)"; return; }

  # The commits endpoint returns a 409 with a JSON error body for empty
  # repos but `gh api --jq` still exits 0 and prints the raw body. Filter
  # the SHA on our side instead, so a 409 yields an empty string.
  p_sha=$(gh_with_account "$PRIMARY" api -X GET "repos/$PRIMARY/$name/commits/$p_branch" 2>/dev/null | jq -r 'if type == "object" and has("sha") then .sha else "" end')
  m_sha=$(gh_with_account "$MIRROR"  api -X GET "repos/$MIRROR/$name/commits/$m_branch" 2>/dev/null | jq -r 'if type == "object" and has("sha") then .sha else "" end')

  # Either repo empty? Treat as drift but a special "needs initial push" one.
  if [[ -z "$p_sha" || -z "$m_sha" ]]; then
    log "drift on $name: one side has no commits ($PRIMARY=${p_sha:-empty} vs $MIRROR=${m_sha:-empty})"
    if (( ! force )); then return; fi
    # fall through to force-push below
  fi

  if [[ "$p_sha" == "$m_sha" && -n "$p_sha" ]]; then
    return
  fi

  log "drift on $name: $PRIMARY@$p_sha vs $MIRROR@$m_sha"
  if (( ! force )); then
    log "  (use 'mirror reconcile --force' to overwrite mirror from primary)"
    return
  fi
  (( dry )) && return

  local tmp
  tmp=$(mktemp -d -t mirror-sync.XXXXXX)
  trap "rm -rf '$tmp'" EXIT
  gh_with_account "$PRIMARY" repo clone "$PRIMARY/$name" "$tmp/repo" -- --mirror --quiet
  git -C "$tmp/repo" push --mirror "https://github.com/$MIRROR/$name.git"
  log "force-synced $PRIMARY/$name → $MIRROR/$name"
)

# Run a git command after temporarily setting credential.useHttpPath so the
# gh-managed credential for the named account is used. Currently a no-op
# wrapper — gh auth setup-git already handles the credential helper —
# kept as a seam in case we add per-account URLs later.
git_with_account() {
  local acct="$1"; shift
  git "$@"
}

# Adopt a local repo into the user's accounts: create on primary + mirror
# (matching the local repo's basename), wire fan-out push, and shove the
# current state up. Preserves any existing 'origin' as 'upstream' so the
# user can still fetch from where they cloned from.
#
# Idempotent: if the destination repos already exist, just re-wires push.
# Strip a token from input so it never lands in logs. Falls back to a
# no-op cat if the token is empty (sed with an empty pattern is undefined
# behaviour on macOS / BSD and can echo the unfiltered URL on some
# builds).
_redact_token() {
  local token="$1"
  if [[ -z "$token" ]]; then
    cat
  else
    # Use a literal-string replace via awk to avoid sed metachar pitfalls
    # if a token contains '|', '/', '&', etc. (gh tokens don't today, but
    # this keeps the redaction robust if that ever changes).
    awk -v t="$token" '{ gsub(t, "***"); print }'
  fi
}

# Sanitize a basename into a GitHub-legal repo name.
# Rules enforced (matches github.com's server-side validation):
#   - allowed chars: A-Z a-z 0-9 . _ -
#   - cannot start with '.', '-', or '_'
#   - cannot be just '.' or '..'
#   - max 100 chars
# Runs of disallowed chars collapse to a single '-'. Returns empty on
# failure; caller must log + skip.
_sanitize_repo_name() {
  local raw="$1" out
  out=$(printf '%s' "$raw" | sed -E 's/[^A-Za-z0-9._-]+/-/g')
  # Strip leading dots, dashes, underscores. GitHub also forbids leading
  # '.' (e.g. '.github' as a repo name → "name can't start with '.'").
  out=$(printf '%s' "$out" | sed -E 's/^[._-]+//; s/[._-]+$//')
  # Reject reserved bare-dot forms after stripping.
  case "$out" in
    ""|"."|"..") printf '' ;;
    *) printf '%s' "${out:0:100}" ;;
  esac
}

claim_local_repo() {
  local repo_dir="$1"
  local raw_name name
  raw_name=$(basename "$repo_dir")
  name=$(_sanitize_repo_name "$raw_name")
  if [[ -z "$name" ]]; then
    log "  skip $repo_dir (empty/illegal name after sanitize from '$raw_name')"
    return 1
  fi

  # Refuse if we can't get a token for either account — otherwise we'd
  # create empty repos and fail at push.
  local primary_token mirror_token
  primary_token=$(gh auth token --user "$PRIMARY" 2>/dev/null || true)
  mirror_token=$(gh auth token --user "$MIRROR" 2>/dev/null || true)
  if [[ -z "$primary_token" || -z "$mirror_token" ]]; then
    local missing_accts=""
    [[ -z "$primary_token" ]] && missing_accts="$PRIMARY"
    [[ -z "$mirror_token"  ]] && missing_accts="${missing_accts:+$missing_accts, }$MIRROR"
    log "  skip $repo_dir (no gh token for: $missing_accts — run 'gh auth login')"
    return 1
  fi

  ( cd "$repo_dir" || exit 1
    # Move existing origin out of the way if it points anywhere but our
    # accounts. Prefer renaming → 'upstream' so the URL is preserved.
    # If 'upstream' is taken, fall back to 'claimed-origin-<N>' rather
    # than dropping the URL — losing the source of truth silently is a
    # data-loss-class bug.
    local existing
    existing=$(git remote get-url origin 2>/dev/null || true)
    if [[ -n "$existing" ]]; then
      local owner="" rname=""
      parse_github_url "$existing" owner rname
      if [[ "$owner" != "$PRIMARY" && "$owner" != "$MIRROR" ]]; then
        if ! git remote get-url upstream >/dev/null 2>&1; then
          git remote rename origin upstream
          log "  $name: kept previous origin as 'upstream' → $existing"
        else
          # Find next free 'claimed-origin-N' slot.
          local n=1 alt
          while alt="claimed-origin-$n"; git remote get-url "$alt" >/dev/null 2>&1; do
            n=$(( n + 1 ))
          done
          git remote rename origin "$alt"
          log "  $name: kept previous origin as '$alt' (upstream already taken) → $existing"
        fi
      fi
    fi

    # Create on PRIMARY first; if that fails, bail before we touch MIRROR
    # or push. If PRIMARY succeeds but MIRROR fails, the subshell exits
    # via set -e before setup_fanout_remote, so we don't end up with a
    # half-wired fan-out remote pointing at a non-existent mirror repo.
    if ! gh_create_repo "$PRIMARY" "$name" "$DEFAULT_VIS" "claimed from $repo_dir"; then
      log "  $name: failed to create on PRIMARY ($PRIMARY) — aborting"
      exit 1
    fi
    if ! gh_create_repo "$MIRROR" "$name" "$DEFAULT_VIS" "mirror of github.com/$PRIMARY/$name"; then
      log "  $name: failed to create on MIRROR ($MIRROR) — PRIMARY repo $PRIMARY/$name was created and is left in place (no delete_repo scope assumed); rerun after fixing the cause"
      exit 1
    fi
    setup_fanout_remote "$PRIMARY" "$MIRROR" "$name"

    # Push current HEAD if we have any commits.
    if git rev-parse HEAD >/dev/null 2>&1; then
      local cur_branch
      cur_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo main)
      # Tokens are embedded in the push URL ONLY for this invocation —
      # never written to .git/config and stripped from any output via
      # _redact_token, including stderr from `git push` itself (the URL
      # is echoed in error messages).
      GIT_TERMINAL_PROMPT=0 git push \
        "https://x-access-token:${primary_token}@github.com/$PRIMARY/$name.git" \
        "$cur_branch":"$cur_branch" --tags 2>&1 \
        | _redact_token "$primary_token" | sed 's/^/    /' || true
      GIT_TERMINAL_PROMPT=0 git push \
        "https://x-access-token:${mirror_token}@github.com/$MIRROR/$name.git" \
        "$cur_branch":"$cur_branch" --tags 2>&1 \
        | _redact_token "$mirror_token" | sed 's/^/    /' || true
    else
      log "  $name: no commits yet — two empty repos created on $PRIMARY and $MIRROR; push manually once you have a commit"
    fi
  )
}
