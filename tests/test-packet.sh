#!/usr/bin/env bash
# factory.sh packet on a synthetic board DB and repo (no real board touched),
# and factory_watch's QA-PASSED-NOT-MERGED line pointing at the packet.
. "$(dirname "$0")/lib.sh"
export FACTORY_STATE_DIR="$TMP/state" HERMES_KANBAN_HOME="$TMP/khome" FACTORY_BOARD="packet-test"
repo="$TMP/repo"; export FACTORY_TARGET_REPO="$repo"
g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }
mkdir -p "$repo"; g init -q -b main
printf 'a\nb\n' > "$repo/f.txt"; g add -A; g commit -qm base
g checkout -q -b factory/p/01-thing; echo new > "$repo/new.txt"; g add -A; g commit -qm "add new"
g checkout -q -b factory/p/02-clash main; printf 'X\nb\n' > "$repo/f.txt"; g commit -qam "clash"
g checkout -q -b factory/p/03-old main; echo old > "$repo/old.txt"; g add -A; g commit -qm old
g checkout -q main; printf 'Y\nb\n' > "$repo/f.txt"; g commit -qam "main moves"; g merge -q --no-ff factory/p/03-old -m merged
wt="$repo/.worktrees/p-01-thing"

db="$HERMES_KANBAN_HOME/kanban/boards/$FACTORY_BOARD/kanban.db"; mkdir -p "$(dirname "$db")"
sqlite3 "$db" <<SQL
create table tasks (id text primary key, title text, body text, status text, assignee text, workspace_kind text,
  workspace_path text, branch_name text, created_at integer, result text);
create table task_runs (id integer primary key, task_id text, profile text, summary text, outcome text);
insert into tasks values ('t_b1', 'Add the thing', 'Make the thing.

Work in the worktree for branch factory/p/01-thing. Commit your changes.', 'done', 'sf-reviewer', 'worktree', '$wt', 'factory/p/01-thing', 1, null);
insert into tasks values ('t_q1', 'QA: Add the thing', 'Verify', 'done', 'sf-qa', 'dir', '$wt', null, 2, null);
insert into task_runs (task_id, profile, summary, outcome) values ('t_b1', 'sf-reviewer', 'Approved: looks right.', 'completed'),
  ('t_q1', 'sf-qa', 'QA passed. ok: GET /api/health 200', 'completed');
insert into tasks values ('t_b2', 'Clash', 'Clashing change.', 'done', 'sf-reviewer', 'worktree', '$repo/.worktrees/p-02-clash', 'factory/p/02-clash', 3, null);
insert into tasks values ('t_b3', 'Old', 'Old change.', 'done', 'sf-reviewer', 'worktree', '$repo/.worktrees/p-03-old', 'factory/p/03-old', 4, null);
SQL
head=$(g rev-parse factory/p/01-thing)
mkdir -p "$FACTORY_STATE_DIR/check-pass" "$FACTORY_STATE_DIR/done-when"
date > "$FACTORY_STATE_DIR/check-pass/$head@p-01-thing"; echo 'test -f new.txt' > "$FACTORY_STATE_DIR/done-when/p-01-thing"

"$ROOT/factory.sh" packet t_q1 >/dev/null 2>&1
p="$FACTORY_STATE_DIR/review/t_b1.md"
[ -f "$p" ] && ok "QA task id resolves to the build's packet" || bad "packet written at $p"
has() { grep -qF -- "$2" "$p" && ok "$1" || bad "$1 (missing: $2)"; }
has "title" "# Review packet: Add the thing"
has "ticket body without the worker boilerplate" "Make the thing."
grep -q "Work in the worktree" "$p" && bad "boilerplate stripped" || ok "boilerplate stripped"
has "done-when" '**Done when:** `test -f new.txt`'
has "check pass incl. done-when" "including the ticket done-when"
has "merges cleanly" "Merges cleanly into main."
has "diff stat" "new.txt | 1 +"
has "commits" "add new"
has "reviewer summary" "Approved: looks right."
has "QA summary with smoke output" "ok: GET /api/health 200"

"$ROOT/factory.sh" packet t_b2 >/dev/null 2>&1; p="$FACTORY_STATE_DIR/review/t_b2.md"
has "conflict reported" "**Conflicts with main** in:"
has "conflicted file listed" "- f.txt"
has "points at the Integrator" "./factory.sh integrate t_b2"
has "no check pass flagged" "No pass recorded"
"$ROOT/factory.sh" packet t_b3 >/dev/null 2>&1; p="$FACTORY_STATE_DIR/review/t_b3.md"
has "already merged" "Already merged into main"

rm -rf "$FACTORY_STATE_DIR/review"
out=$("$ROOT/factory.sh" packet t_b1 --dry-run 2>&1)
[ -d "$FACTORY_STATE_DIR/review" ] && bad "dry-run writes nothing" || ok "dry-run writes nothing"
rc=0; out=$("$ROOT/factory.sh" packet t_b1 --pr --dry-run 2>&1) || rc=$?
case "$rc:$out" in [1-9]*"needs a GitHub 'origin' remote"*) ok "--pr refuses without a GitHub remote" ;; *) bad "--pr no remote: $out" ;; esac
g remote add origin git@github.com:example/repo.git
if gh auth status >/dev/null 2>&1; then
  out=$("$ROOT/factory.sh" packet t_b1 --pr --dry-run 2>&1)
  case "$out" in *"[dry-run] git -C"*"push -u origin factory/p/01-thing"*"[dry-run] gh pr create"*"--draft"*) ok "--pr --dry-run only prints push and draft PR" ;; *) bad "--pr dry-run: $out" ;; esac
fi
rc=0; "$ROOT/factory.sh" packet t_nope >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] && ok "unknown task refused" || bad "unknown task refused"

# factory_watch.review_packet() with a stub factory.sh
stubroot="$TMP/froot"; mkdir -p "$stubroot"
printf '#!/bin/sh\necho "==> Review packet: %s/.factory/review/t_b9.md"\n' "$stubroot" > "$stubroot/factory.sh"; chmod +x "$stubroot/factory.sh"
line=$(python3 -I -c "
src = open('$ROOT/scripts/factory_watch.py').read(); src = src[:src.index('problems = merge_problems()')]
g = {}; exec(src, g); g['FACTORY'] = '$stubroot'; print(g['review_packet']('t_q9'))")
expect "factory_watch names the packet" "$line" "review packet .factory/review/t_b9.md, then test-merge it into main"
done_testing
