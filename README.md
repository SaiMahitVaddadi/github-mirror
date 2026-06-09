# github-mirror

Keep two GitHub accounts in sync.

You sign every repo into both accounts; the same code is available from either. Two layers of sync work together:

1. **Fan-out push.** `git push origin` writes to BOTH accounts in one command, because `origin`'s pushURL is configured to point at both remotes. No daemons; this is just `git remote set-url --add --push` plumbing.
2. **Reconciler.** `mirror reconcile` walks both accounts via the GitHub API and creates anything missing on either side, then pushes its refs across. Safe by default — divergent histories are reported, not overwritten. `--force` opts in to mirror-style push.

Run the reconciler on demand, or install a launchd job so macOS runs it hourly.

## Why

You have two GitHub identities — a personal account and a work / alt / pseudonym — and you want every repo to exist on both, so:

- a push from either machine, under either identity, ends up on both,
- the "wrong" identity opening a repo URL still finds the code,
- losing access to one account doesn't lose the repo.

This isn't a webhook-driven mirror service or a GitHub App. It's a thin shell wrapper around `gh` + `git`, designed to be readable in one afternoon.

## Requirements

- macOS or Linux, bash 4+
- [`gh`](https://cli.github.com/) authenticated to both accounts (`gh auth login` for each)
- `git`, `jq`

```bash
gh auth status
# Should list two accounts. If not:
gh auth login
gh auth login   # again, for the second
```

## Install

```bash
git clone https://github.com/<you>/github-mirror ~/Documents/Github/github-mirror
~/Documents/Github/github-mirror/install.sh
mirror init
```

`install.sh` symlinks `bin/mirror` into `/usr/local/bin/`. Override the install target with `BIN_DIR=~/.local/bin ./install.sh` if you don't want sudo.

## Usage

```bash
mirror init                            # one-time setup, picks primary + mirror
mirror status                          # list every repo on either account, presence marks
mirror new my-repo --private           # create on BOTH accounts; clone with fan-out push
mirror clone owner/some-repo           # gh clone; wire fan-out push so future pushes go to both
mirror adopt                           # inside an existing repo, add the other account as a push target
mirror push                            # convenience wrapper; same as `git push`
mirror audit                           # walk ~/Documents/Github + ~/coding-agents, classify every .git
mirror audit --apply                   # ...and claim every not-ours repo onto both accounts
mirror reconcile                       # create missing repos on either side, push their refs
mirror reconcile --force               # also overwrite divergent histories (primary wins)
mirror watch                           # run reconcile every reconcile_interval_min
mirror install-launchd                 # macOS only: register hourly launchd job
mirror uninstall-launchd
```

## Audit + claim

`mirror audit` walks a list of paths (default `~/Documents/Github` and `~/coding-agents`), finds every `.git` directory, reads its `origin` remote, and classifies it:

- **ours** — origin points at `$PRIMARY` or `$MIRROR`.
- **external** — origin points at github.com but a different owner (open-source clones, work repos, etc.).
- **other** — origin is non-GitHub (GitLab, Bitbucket, self-hosted).
- **none** — no `origin` remote configured.

Output goes to stdout as TSV; summary tallies go to stderr — `mirror audit | grep external` works.

### Flags

- `--apply` — for every not-ours repo, create it on `$PRIMARY` and `$MIRROR`, wire the fan-out push, and push current `HEAD` (plus tags). Idempotent: re-running re-wires the remote and re-pushes.
- `--dry-run` — with `--apply`, print what would be claimed without calling the API.
- `--no-nested` — skip repos that live inside another already-counted repo (e.g. `node_modules/<pkg>/.git`).
- `--ignore <glob>` — skip paths matching a glob. Can be passed multiple times. Tilde is expanded.
- `--resume-from <path>` — with `--apply`, skip every repo up to and including `<path>`. Progress is written to `$STATE_DIR/audit.progress` after each apply, so you can grab the last `ok` line and resume after a crash.

### What `--apply` does on a not-ours repo

1. **Sanitize the directory's basename** into a GitHub-legal repo name. Strips leading `.`, `-`, `_` (GitHub rejects names starting with any of these), collapses disallowed chars to `-`, caps at 100 chars. Names that sanitize to empty (`..`, `___`) are skipped with a log line.
2. **Rename the previous `origin` to `upstream`** so you can still fetch from where the code came from. If `upstream` already exists, falls back to `claimed-origin-N` — the original URL is never silently dropped.
3. **Create the repo on `$PRIMARY` then `$MIRROR`**. If `$PRIMARY` create fails, abort before touching `$MIRROR`. If `$PRIMARY` succeeds but `$MIRROR` fails (rate limit, name collision), the run aborts with a clear log line — the `$PRIMARY` repo is left in place, since this tool doesn't request `delete_repo` scope. Re-run after fixing the cause.
4. **Wire the fan-out push** on `origin` (both URLs).
5. **Push current HEAD + tags** to both URLs, using per-account tokens fetched fresh from `gh auth token --user <acct>`. **Tokens are embedded into the push URL only for the duration of the single `git push` invocation** — they are never written to `.git/config`. All output from the `git push` (including stderr, which is where git echoes the URL on failure) is piped through a token-stripping filter that replaces the token with `***` before it reaches the terminal or log.

### Caveats

- If a repo has no commits yet, the two GitHub repos are still created (empty); you'll see a log line telling you to push manually once you have a commit. (There's no rollback because this tool doesn't request `delete_repo` scope.)
- `find` is run with stderr captured; if any paths under the audit roots were unreadable, the summary prints a warning naming the first few — no permission errors silently swallow repos.
- Token redaction uses an `awk` literal-string replace rather than `sed`, because tokens may contain characters that are metacharacters in sed (`|`, `/`, `&`). If the token is empty (`gh auth token` returned nothing), the redaction is a no-op `cat` — but the call sites refuse to push in that case, so the empty token is never embedded into a URL.

## How fan-out push works

`git remote -v` after `mirror adopt`:

```
origin  https://github.com/primary/repo.git (fetch)
origin  https://github.com/primary/repo.git (push)
origin  https://github.com/mirror/repo.git  (push)
```

`git push origin main` writes to both push URLs in one go. The fetch URL stays a single source (primary) — you don't want fetches racing between accounts. If primary diverges, just `mirror reconcile --force` to make mirror catch up.

## Config

`~/.config/github-mirror/config.json`:

```json
{
  "primary": "primary-account",
  "mirror":  "mirror-account",
  "accounts": ["primary-account", "mirror-account"],
  "default_visibility": "private",
  "reconcile_interval_min": 60,
  "ignore": ["very-secret-repo", "experimental-fork"]
}
```

`ignore` matches by repo name. Archived repos are excluded via `gh repo list --no-archived` (server-side, no wire bytes paid for archived ones).

## Reconciler semantics

For each repo name that appears on either account:

- **Missing on the other side** → create it (matches visibility of source), clone source with `--mirror`, push every ref to destination.
- **Present on both, same default-branch tip SHA** → no-op.
- **Present on both, different tip SHAs** → log the drift. Without `--force`, do nothing. With `--force`, mirror-push from primary to mirror, overwriting mirror's history.

The reconciler never deletes a repo on either side. If you want a repo gone on both, delete it on each account manually — losing both copies should require deliberate action.

## Logs

```
~/.local/state/github-mirror/mirror.log
```

Every reconcile run, every create, every fan-out wiring lands here.

## launchd job (macOS)

`mirror install-launchd` writes `~/Library/LaunchAgents/com.github-mirror.reconcile.plist` and `launchctl load`s it. The job runs `mirror reconcile` every hour, logs to the same file as above. `mirror uninstall-launchd` removes both.

## Caveats

- `gh repo create` requires the active account to be the destination, so the script flips `gh auth switch` around each create call. If something else is holding the active account, `mirror reconcile` may briefly steal it.
- Fan-out push doesn't verify both URLs succeeded in one pass — git reports the second URL's outcome. If a push to mirror fails (e.g. branch-protection rule), you'll see the error but primary already accepted. Re-running `git push origin main` retries both.
- Large bare clones during reconcile use `mktemp -d`. If reconciling many large repos, ensure `$TMPDIR` has room.

## Why not GitHub's built-in fork sync / mirror?

GitHub forks are upstream-tracked — they're a 1:N copy pinned to a parent. This tool is for 1:1 mirrors of repos you own on both accounts, with neither labelled "fork of." It's also entirely client-side, so no GitHub App / Marketplace involvement.

## License

MIT.
