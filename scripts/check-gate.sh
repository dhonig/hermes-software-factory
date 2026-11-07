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
# (factory.conf, 0 = no limit); anything it leaves running is killed.
. "$(dirname "$0")/../lib/common.sh"

[ $# -ge 1 ] || die "usage: check-gate.sh <worktree-path>"
wt="$(cd "$1" && pwd)" || die "No such worktree: $1"
[ -x "$wt/check.sh" ] || die "$wt has no executable check.sh"

sha=$(git -C "$wt" rev-parse HEAD)
# Tests can touch tracked fixtures, so look at the tree before running them.
dirty=0
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
if [ "$dirty" = 1 ]; then
  warn "check.sh passed, but the worktree has uncommitted changes, so nothing was recorded. Commit and run this again."
  exit 1
fi
mkdir -p "$STATE_DIR/check-pass"
date '+%Y-%m-%dT%H:%M:%S%z' > "$STATE_DIR/check-pass/$sha"
log "check.sh passed on $sha (recorded)"
