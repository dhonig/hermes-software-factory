#!/usr/bin/env bash
# factory.sh pause / resume round trip on a scratch board. Needs the hermes CLI.
# Board data goes to a temp HERMES_KANBAN_HOME (never HERMES_HOME), and the
# board name doesn't exist in the real home, so the real board can't be touched.
# Slow: each hermes call takes a few seconds.
. "$(dirname "$0")/lib.sh"
command -v hermes >/dev/null || { echo "skip: hermes not installed"; exit 0; }
export HERMES_KANBAN_HOME="$TMP/khome" FACTORY_BOARD="pause-test-$$" FACTORY_STATE_DIR="$TMP/state"
STATE="$FACTORY_STATE_DIR"
kb() { hermes kanban --board "$FACTORY_BOARD" "$@" </dev/null; }
mk() { kb create "$@" --assignee nobody --json | jq -r '.id // .task.id'; }
st() { sqlite3 -cmd "PRAGMA query_only = ON" "$HERMES_KANBAN_HOME/kanban/boards/$FACTORY_BOARD/kanban.db" "select status from tasks where id = '$1'"; }

hermes kanban boards create "$FACTORY_BOARD" >/dev/null </dev/null
a=$(mk "ready card"); b=$(mk "todo card" --parent "$a")
c=$(mk "running card"); kb claim "$c" >/dev/null
d=$(mk "review card"); kb claim "$d" >/dev/null; kb request-review "$d" --reviewer nobody --summary "done" >/dev/null
e=$(mk "blocked card"); kb block "$e" "a real problem" >/dev/null
expect "fixture: ready"   "$(st "$a")" ready
expect "fixture: todo"    "$(st "$b")" todo
expect "fixture: running" "$(st "$c")" running
expect "fixture: review"  "$(st "$d")" review
expect "fixture: blocked" "$(st "$e")" blocked

"$ROOT/factory.sh" pause "test" --dry-run >/dev/null 2>&1
expect "dry-run changes nothing" "$(st "$a")$(st "$c")" readyrunning
[ -f "$STATE/paused-tasks.txt" ] && bad "dry-run writes no record" || ok "dry-run writes no record"

"$ROOT/factory.sh" pause "test" >/dev/null 2>&1
for t in "$a" "$b" "$c" "$d"; do expect "pause holds $t" "$(st "$t")" scheduled; done
expect "pause leaves the blocked card alone" "$(st "$e")" blocked
grep -q "^$e .*untouched" "$STATE/paused-tasks.txt" && ok "blocked card recorded as untouched" || bad "blocked card recorded as untouched"
rc=0; "$ROOT/factory.sh" pause again >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] && ok "pause refuses when already paused" || bad "pause refuses when already paused"

"$ROOT/factory.sh" resume --force >/dev/null 2>&1
expect "resume: ready card is ready"  "$(st "$a")" ready
expect "resume: todo card waits on its parent" "$(st "$b")" todo
expect "resume: running card is ready to run again" "$(st "$c")" ready
expect "resume: review card is back in review" "$(st "$d")" review
expect "resume: blocked card is still blocked" "$(st "$e")" blocked
[ -f "$STATE/paused-tasks.txt" ] && bad "record archived" || ok "record archived"
ls "$STATE"/paused-tasks.2*.txt >/dev/null 2>&1 && ok "archived record kept" || bad "archived record kept"

done_testing
