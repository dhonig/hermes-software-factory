#!/usr/bin/env bash
# scripts/cost.py on a synthetic board DB (only the columns it reads).
. "$(dirname "$0")/lib.sh"
db="$TMP/kanban.db"; state="$TMP/state"; mkdir -p "$state/escalations"
sqlite3 "$db" <<'SQL'
create table tasks (id text primary key, title text, status text, assignee text, workspace_kind text,
  workspace_path text, branch_name text, created_at integer);
create table task_runs (id integer primary key, task_id text, started_at integer, ended_at integer, outcome text);
-- delivered ticket: build + security + QA in /wt/a, one crash, one escalation
insert into tasks values ('t_build_a', 'Ticket A', 'done', 'sf-reviewer', 'worktree', '/wt/a', 'factory/a', 1);
insert into tasks values ('t_sec_a', 'Security check: Ticket A', 'done', 'sf-security', 'dir', '/wt/a', null, 2);
insert into tasks values ('t_qa_a', 'QA: Ticket A', 'done', 'sf-qa', 'dir', '/wt/a', null, 3);
insert into task_runs (task_id, started_at, ended_at, outcome) values
  ('t_build_a', 0, 600, 'crashed'), ('t_build_a', 600, 1800, 'review_requested'),
  ('t_sec_a', 1800, 2100, 'completed'), ('t_qa_a', 2100, 2400, 'blocked'), ('t_qa_a', 2400, 3000, 'completed');
-- open ticket: QA still todo
insert into tasks values ('t_build_b', 'Ticket B', 'done', 'sf-reviewer', 'worktree', '/wt/b', 'factory/b', 4);
insert into tasks values ('t_qa_b', 'QA: Ticket B', 'todo', 'sf-qa', 'dir', '/wt/b', null, 5);
insert into task_runs (task_id, started_at, ended_at, outcome) values ('t_build_b', 0, 120, 'timed_out');
-- planner
insert into tasks values ('t_plan', 'Plan: x', 'done', 'sf-planner', 'scratch', '/scratch', null, 0);
insert into task_runs (task_id, started_at, ended_at, outcome) values ('t_plan', 0, 300, 'completed');
SQL
date > "$state/escalations/t_build_a.marker"
echo '{"num_turns": 12, "total_cost_usd": 1.25, "usage": {"input_tokens": 1000, "output_tokens": 200, "cache_read_input_tokens": 300}}' \
  > "$state/escalations/t_build_a.log"

j=$(python3 -I "$ROOT/scripts/cost.py" --db "$db" --state "$state" --json)
expect "delivered only by default" "$(printf '%s' "$j" | jq '.tickets | length')" 1
expect "ticket is the build task" "$(printf '%s' "$j" | jq -r '.tickets[0].id')" t_build_a
expect "agent minutes over all runs in the worktree" "$(printf '%s' "$j" | jq '.tickets[0].minutes | floor')" 50
expect "runs" "$(printf '%s' "$j" | jq '.tickets[0].runs')" 5
expect "failed runs (crash)" "$(printf '%s' "$j" | jq '.tickets[0].failed')" 1
expect "blocked runs counted apart" "$(printf '%s' "$j" | jq '.tickets[0].blocked')" 1
expect "escalations" "$(printf '%s' "$j" | jq '.tickets[0].escalations')" 1
expect "Claude cost" "$(printf '%s' "$j" | jq '.tickets[0].claude_usd')" 1.25
expect "Claude tokens" "$(printf '%s' "$j" | jq '.tickets[0].claude_tokens')" 1500
expect "planning runs apart" "$(printf '%s' "$j" | jq '.planning.runs')" 1
j=$(python3 -I "$ROOT/scripts/cost.py" --db "$db" --state "$state" --json --all)
expect "--all includes open tickets" "$(printf '%s' "$j" | jq '.tickets | length')" 2
expect "open ticket not delivered" "$(printf '%s' "$j" | jq '[.tickets[] | select(.id == "t_build_b")][0].delivered')" false
out=$(python3 -I "$ROOT/scripts/cost.py" --db "$db" --state "$TMP/none")
case "$out" in *"t_build_a"*"total"*) ok "table renders without an escalations dir" ;; *) bad "table: $out" ;; esac
sqlite3 "$TMP/empty.db" "create table tasks (id, title, status, assignee, workspace_kind, workspace_path, branch_name, created_at); create table task_runs (id, task_id, started_at, ended_at, outcome);"
out=$(python3 -I "$ROOT/scripts/cost.py" --db "$TMP/empty.db" --state "$state")
case "$out" in *"no delivered tickets"*) ok "empty board" ;; *) bad "empty board: $out" ;; esac
# read-only: the DB file is unchanged
before=$(md5 -q "$db" 2>/dev/null || md5sum "$db" | cut -d' ' -f1)
python3 -I "$ROOT/scripts/cost.py" --db "$db" --state "$state" >/dev/null
after=$(md5 -q "$db" 2>/dev/null || md5sum "$db" | cut -d' ' -f1)
expect "DB unchanged" "$after" "$before"
done_testing
