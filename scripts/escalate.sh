#!/usr/bin/env bash
# Hand a stuck build task to headless Claude Code in the task's worktree, then put
# it back in the normal flow: it still goes through review, security and QA.
#
#   scripts/escalate.sh <task-id> ["note"]
#
# Runs once per call; the factory-watch cron only calls it once per task (the
# marker in .factory/escalations/). Log: .factory/escalations/<task>.log
. "$(dirname "$0")/../lib/common.sh"
eval "set -- $(strip_flags "$@")"

[ $# -ge 1 ] || die "usage: escalate.sh <task-id> [\"note\"]"
id="$1"; note="${2:-}"
dir="$STATE_DIR/escalations"; mkdir -p "$dir"
out="$dir/$id.log"; prompt="$dir/$id.prompt.md"; lock="$dir/.lock"

# The caller's environment may belong to another Claude session or a Hermes worker.
clean_env() { env -i HOME="$HOME" USER="${USER:-}" PATH="$PATH" LANG="${LANG:-en_US.UTF-8}" TERM=dumb "$@"; }

command -v claude >/dev/null || die "claude is not on PATH"
clean_env claude auth status 2>/dev/null | jq -e '.loggedIn == true' >/dev/null \
  || die "claude is not logged in. Run 'claude auth login' on this machine, then try again."

json=$(kanban show "$id" --json) || die "No task $id on board $BOARD."
status=$(printf '%s' "$json" | jq -r '.task.status')
title=$(printf '%s' "$json" | jq -r '.task.title')
assignee=$(printf '%s' "$json" | jq -r '.task.assignee')
wt=$(printf '%s' "$json" | jq -r '.task.workspace_path // empty')
case "$assignee" in
  "$(profile_name backend)") role=backend ;;
  "$(profile_name frontend)") role=frontend ;;
  "$(profile_name integrator)") role=integrator ;;
  *) die "$id is assigned to $assignee; only builder and integrator tasks can be escalated." ;;
esac
[ -n "$wt" ] && [ -x "$wt/check.sh" ] || die "$id has no worktree with a check.sh: ${wt:-none}"
[ "$status" = running ] && die "$id is running; wait for it to stop or block it first."
case "$status" in blocked|ready|todo) ;; *) die "$id is $status; nothing to escalate." ;; esac
[ "$DRY_RUN" = 1 ] && { log "Would escalate $id ($title) in $wt"; exit 0; }

mkdir "$lock" 2>/dev/null || die "Another escalation is running ($lock)."
trap 'rmdir "$lock" 2>/dev/null || true' EXIT
date '+%Y-%m-%dT%H:%M:%S%z' > "$dir/$id.marker"

# Hold the task so the dispatcher can't start a worker in the same worktree.
[ "$status" = blocked ] || kanban block "$id" "escalated to Claude Code" >/dev/null

{
  echo "You are fixing a stuck ticket in a software factory. A local model could not finish it."
  echo
  echo "## Ticket $id: $title"
  printf '%s\n' "$json" | jq -r '.task.body'
  echo
  echo "## Why it is stuck"
  printf '%s\n' "$json" | jq -r '.latest_summary // "unknown"'
  echo
  echo "## Recent comments"
  printf '%s\n' "$json" | jq -r '[.comments[]?.body] | .[-3:] | .[]'
  [ -n "$note" ] && { echo; echo "## Note from the operator"; echo "$note"; }
  echo
  echo "## Role rules"
  render_role "$role"
  echo
  echo "## Your job"
  echo "Make ./check.sh pass and meet the ticket's acceptance criteria. Fix only what is needed."
  echo "Uncommitted work in this worktree is the builder's: keep it unless it is wrong."
  echo "Never delete or weaken a test. Never remove a safety guard: the query_only pragma, the Origin check, input validation."
  echo "Stay inside this worktree. Ignore the role's instructions about kanban tools: the factory hands off for you."
  echo "When ./check.sh exits 0, commit everything with one short one-line message and stop."
} > "$prompt"

log "Escalating $id to Claude Code in $wt (log: $out)"
rc=0
(cd "$wt" && clean_env claude -p "$(cat "$prompt")" \
  --permission-mode acceptEdits --max-turns "$ESCALATE_MAX_TURNS" --max-budget-usd "$ESCALATE_MAX_BUDGET_USD" \
  --output-format json \
  --allowedTools "Read" "Edit" "Write" "Glob" "Grep" \
    "Bash(cargo:*)" "Bash(trunk:*)" "Bash(./check.sh)" \
    "Bash(git diff:*)" "Bash(git status:*)" "Bash(git log:*)" "Bash(git add:*)" "Bash(git commit:*)") > "$out" 2>&1 || rc=$?

turns=$(jq -r '.num_turns // "?"' "$out" 2>/dev/null || echo '?')
cost=$(jq -r '.total_cost_usd // "?"' "$out" 2>/dev/null || echo '?')
said=$(jq -r '.result // empty' "$out" 2>/dev/null | head -c 600 || true)

# The model's word doesn't count: the check gate decides.
if [ "$rc" = 0 ] && "$FACTORY_ROOT/scripts/check-gate.sh" "$wt" >> "$out.check" 2>&1; then
  sha=$(git -C "$wt" rev-parse --short HEAD)
  kanban comment "$id" "Escalated to Claude Code: fixed. Commit $sha, $turns turns, \$$cost. $said" >/dev/null
  # request-review only accepts ready or running tasks. --force covers the dispatcher
  # claiming it between these two calls.
  kanban unblock "$id" >/dev/null
  kanban request-review "$id" --force --reviewer "$(profile_name reviewer)" \
    --summary "Finished by the Claude Code escalation at $sha; factory.sh check passed. Review as usual." >/dev/null || true
  now=$(kanban show "$id" --json | jq -r '.task.status')
  [ "$now" = review ] || die "$id was fixed at $sha but is $now, not review: hand it over by hand."
  log "Escalation fixed $id at $sha ($turns turns, \$$cost); handed to review"
else
  kanban comment "$id" "Escalated to Claude Code: not fixed (exit $rc, $turns turns, \$$cost). Log: $out. $said" >/dev/null
  warn "Escalation did not fix $id; it stays blocked for a person. Log: $out"
  exit 1
fi
