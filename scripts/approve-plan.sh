#!/usr/bin/env bash
# Turn an approved Planner plan into build tasks.
#
# For each plan line this creates:
#   build (backend/frontend, own worktree + branch, reviewed by the Reviewer)
#     -> security check (same worktree)
#       -> QA (same worktree)
# Build tasks are chained so only one builds at a time, which keeps merges simple.
#
#   scripts/approve-plan.sh <planner-task-id> [--yes]
. "$(dirname "$0")/../lib/common.sh"
eval "set -- $(strip_flags "$@")"
require_target_repo

[ $# -ge 1 ] || die "usage: approve-plan.sh <planner-task-id> [--yes]"
plan_id="$1"; yes=0
[ "${2:-}" = "--yes" ] && yes=1

plan_file="$STATE_DIR/plans/$plan_id.md"
mkdir -p "$STATE_DIR/plans"

if [ ! -f "$plan_file" ]; then
  json=$(kanban show "$plan_id" --json) || die "No task $plan_id on board $BOARD."
  status=$(printf '%s' "$json" | jq -r '.task.status')
  [ "$status" = done ] || die "Planner task $plan_id is '$status', not done. Check it with: ./factory.sh status"
  plan_re='^[[:space:]]*-[[:space:]]*\[(backend|frontend)\]'
  # Prefer the completion summary. Small local models sometimes write the plan
  # in their reply but put something else in kanban_complete, so fall back to
  # comments and then the worker log (first copy of each line, in order).
  log_file="$HOME/.hermes/kanban/boards/$BOARD/logs/$plan_id.log"
  { printf '%s' "$json" | jq -r '.latest_summary // "", .task.result // ""' | grep -E "$plan_re"; } > "$plan_file" \
    || { printf '%s' "$json" | jq -r '.comments[]?.body // ""' | grep -E "$plan_re"; } > "$plan_file" \
    || { [ -f "$log_file" ] && grep -E "$plan_re" "$log_file" | awk '!seen[$0]++'; } > "$plan_file" \
    || { rm -f "$plan_file"; die "Couldn't find plan lines ('- [backend] title :: details') from the Planner. Check $log_file"; }
  sed -i '' -E 's/^[[:space:]]+//' "$plan_file"
fi

echo "Plan ($plan_file):"
sed 's/^/  /' "$plan_file"
echo

if [ "$yes" != 1 ] && [ "$DRY_RUN" != 1 ]; then
  read -r -p "Create these tasks? [y]es / [e]dit / [N]o: " ans
  case "$ans" in
    y|Y) ;;
    e|E) "${EDITOR:-vi}" "$plan_file"; exec "$0" "$plan_id" ;;
    *) echo "Nothing created. Edit $plan_file and rerun to change the plan."; exit 0 ;;
  esac
fi

reviewer=$(profile_name reviewer)
prev_build=""
n=0
while IFS= read -r line; do
  n=$((n + 1))
  role=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*\[([a-z]+)\].*/\1/')
  rest=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*\[[a-z]+\][[:space:]]*//')
  title=$(printf '%s' "$rest" | awk -F' :: ' '{print $1}')
  scope=$(printf '%s' "$rest" | awk -F' :: ' '{print $2}')
  slug="$(printf '%02d' "$n")-$(slugify "$title")"
  branch="factory/${plan_id#t_}/$slug"
  wt="$WORKTREE_ROOT/${plan_id#t_}-$slug"
  key="$plan_id:$n"

  parent_args=()
  [ -n "$prev_build" ] && parent_args=(--parent "$prev_build")

  build=$(create_task "$title" --assignee "$(profile_name "$role")" \
    --workspace "worktree:$wt" --branch "$branch" --created-by factory \
    --idempotency-key "$key:build" ${parent_args[@]+"${parent_args[@]}"} \
    --body "$scope

Work in the worktree for branch $branch. Commit your changes on that branch.
When done, call kanban_request_review with reviewer="$reviewer". Always pass the
reviewer; without it you would be asked to review your own work.
Plan: $plan_id. Shared memory: .ecc/memory/ in the worktree.")

  sec=$(create_task "Security check: $title" --assignee "$(profile_name security)" \
    --workspace "dir:$wt" --parent "$build" --created-by factory \
    --idempotency-key "$key:security" \
    --body "Security-check the diff of branch $branch against the default branch. Build task: $build.")

  qa=$(create_task "QA: $title" --assignee "$(profile_name qa)" \
    --workspace "dir:$wt" --parent "$sec" --created-by factory \
    --idempotency-key "$key:qa" \
    --body "Verify branch $branch end to end. Acceptance criteria: $scope")

  for t in "$build" "$sec" "$qa"; do notify_discord "$t"; done
  log "[$role] $title: build $build -> security $sec -> qa $qa"
  prev_build="$build"
done < "$plan_file"

log "Created $n build chains. Watch them with: ./factory.sh status"
