#!/usr/bin/env bash
# lib/run-limited.pl and the check gate's timeout. No board or model needed.
. "$(dirname "$0")/lib.sh"
W="$ROOT/lib/run-limited.pl"

rc=0; "$W" 5 sh -c 'exit 3' || rc=$?
expect "passes the exit code through" "$rc" 3

rc=0; "$W" 1 sh -c 'sleep 30' 2>/dev/null || rc=$?
expect "times out with 124" "$rc" 124

rc=0; RUN_LIMITED_GRACE=1 "$W" 1 sh -c 'trap "" TERM; while :; do sleep 0.2; done' 2>/dev/null || rc=$?
expect "KILLs a command that ignores TERM" "$rc" 124

"$W" 5 sh -c "sleep 30 & echo \$! > $TMP/bg"; sleep 0.3
alive "$(cat "$TMP/bg")" && bad "kills a backgrounded child when the command exits" || ok "kills a backgrounded child when the command exits"

rc=0; "$W" 0 true || rc=$?
expect "0 means no limit" "$rc" 0

rc=0; "$W" 5 /nonexistent/cmd 2>/dev/null || rc=$?
expect "missing command exits 127" "$rc" 127

# Check gate: a hanging check.sh fails with 124 and records no pass.
wt="$TMP/wt"; mkdir -p "$wt"
printf '#!/bin/sh\nsleep 30 &\necho $! > bgpid\nexec sleep "${HANG:-0}"\n' > "$wt/check.sh"; chmod +x "$wt/check.sh"
echo bgpid > "$wt/.gitignore"
git -C "$wt" init -q && git -C "$wt" add -A && git -C "$wt" -c user.name=t -c user.email=t@t commit -qm init
sha=$(git -C "$wt" rev-parse HEAD)
rc=0; HANG=60 CHECK_TIMEOUT=1 "$ROOT/scripts/check-gate.sh" "$wt" >/dev/null 2>&1 || rc=$?
expect "check gate times out with 124" "$rc" 124
[ -f "$ROOT/.factory/check-pass/$sha" ] && bad "no pass recorded on timeout" || ok "no pass recorded on timeout"
alive "$(cat "$wt/bgpid")" && bad "check.sh's background child killed" || ok "check.sh's background child killed"
rc=0; CHECK_TIMEOUT=10 "$ROOT/scripts/check-gate.sh" "$wt" >/dev/null 2>&1 || rc=$?
expect "check gate passes" "$rc" 0
[ -f "$ROOT/.factory/check-pass/$sha" ] && ok "pass recorded" || bad "pass recorded"
rm -f "$ROOT/.factory/check-pass/$sha"

done_testing
