#!/usr/bin/env bash
# Run a worktree's ./check.sh and record a pass for its HEAD commit. The
# factory-guard plugin refuses hand-offs unless .factory/check-pass/<sha> exists,
# so a branch can't reach review, security, QA or a person without really passing.
#
#   scripts/check-gate.sh <worktree-path>
#
# A pass only counts for committed code: with uncommitted tracked changes it
# still runs the checks, but records nothing.
#
# ./check.sh runs in its own process group, limited to CHECK_TIMEOUT seconds
# (check.timeout / check.smoke_timeout in factory.toml, 0 = no limit); anything it leaves running is killed.
#
# Fast-lane tickets (factory.sh ticket) also have a done-when command in
# .factory/done-when/<worktree-name>; it runs after ./check.sh under the same
# limit, and a pass is only recorded when both exit 0.
#
# Then the security scanners run (scripts/scan.sh: gitleaks, semgrep; SCANNERS
# check.scanners in factory.toml). A finding fails the gate; a scanner that isn't installed is
# skipped with a warning.
. "$(dirname "$0")/../lib/common.sh"

[ $# -ge 1 ] || die "usage: check-gate.sh <worktree-path>"
wt="$(cd "$1" && pwd)" || die "No such worktree: $1"
[ -x "$wt/check.sh" ] || die "$wt has no executable check.sh"

sha=$(git -C "$wt" rev-parse HEAD)
# Tests can touch tracked fixtures, so look at the tree before running them.
dirty=0; done_when=""
git -C "$wt" diff --quiet HEAD || dirty=1

log "Running ./check.sh on $sha in $wt (limit ${CHECK_TIMEOUT}s)"
rc=0
(cd "$wt" && run_limited "$CHECK_TIMEOUT" ./check.sh) || rc=$?
if [ "$rc" = 124 ]; then
  printf '%sFAIL:%s check.sh timed out after %ss on %s (CHECK_TIMEOUT); its processes were killed\n' \
    "$C_RED" "$C_OFF" "$CHECK_TIMEOUT" "$sha"
  exit "$rc"
elif [ "$rc" != 0 ]; then
  printf '%sFAIL:%s check.sh exited %s on %s\n' "$C_RED" "$C_OFF" "$rc" "$sha"
  exit "$rc"
fi
done_file="$STATE_DIR/done-when/$(basename "$wt")"
if [ -f "$done_file" ]; then
  done_when=$(cat "$done_file")
  log "Running the ticket's done-when in $wt: $done_when"
  rc=0
  (cd "$wt" && run_limited "$CHECK_TIMEOUT" sh -c "$done_when") || rc=$?
  if [ "$rc" != 0 ]; then
    printf '%sFAIL:%s done-when exited %s on %s: %s\n' "$C_RED" "$C_OFF" "$rc" "$sha" "$done_when"
    exit "$rc"
  fi
fi
if [ -n "$SCANNERS" ]; then
  rc=0
  "$FACTORY_ROOT/scripts/scan.sh" "$wt" || rc=$?
  if [ "$rc" != 0 ]; then
    printf '%sFAIL:%s security scan failed on %s\n' "$C_RED" "$C_OFF" "$sha"
    exit "$rc"
  fi
fi
if [ "$dirty" = 1 ]; then
  warn "check.sh passed, but the worktree has uncommitted changes, so nothing was recorded. Commit and run this again."
  exit 1
fi
mkdir -p "$STATE_DIR/check-pass"
# A ticket's pass is keyed by commit and worktree, so a plain pass for the same
# commit elsewhere (e.g. main before the builder commits) doesn't count for it.
pass_file="$STATE_DIR/check-pass/$sha"
[ -n "$done_when" ] && pass_file="$pass_file@$(basename "$wt")"
date '+%Y-%m-%dT%H:%M:%S%z' > "$pass_file"
log "check.sh${done_when:+ and done-when} passed on $sha (recorded)"
