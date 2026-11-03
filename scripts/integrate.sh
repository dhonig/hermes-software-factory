#!/usr/bin/env bash
# Hand a QA-passed branch that doesn't merge cleanly into main to the Planner.
# The Planner gets its own worktree on a fresh integrate/<slug> branch cut from
# main, merges the build branch into it, resolves conflicts and wires up
# routes/modules/fixtures until ./check.sh passes. A person merges the result.
#
#   scripts/integrate.sh <build-task-id> ["what failed when merging"]
. "$(dirname "$0")/../lib/common.sh"
eval "set -- $(strip_flags "$@")"
require_target_repo

[ $# -ge 1 ] || die "usage: integrate.sh <build-task-id> [\"what failed\"]"
build_id="$1"; failure="${2:-}"

json=$(kanban show "$build_id" --json) || die "No task $build_id on board $BOARD."
branch=$(printf '%s' "$json" | jq -r '.task.branch_name // empty')
title=$(printf '%s' "$json" | jq -r '.task.title')
[ -n "$branch" ] || die "Task $build_id has no branch; only build tasks can be integrated."

slug=$(slugify "${branch##*/}")
int_branch="integrate/$slug"
wt="$WORKTREE_ROOT/integrate-$slug"

body_file="$STATE_DIR/integrate-body.$$.md"
cat > "$body_file" <<EOF
Integration task for build $build_id ($title).

Your worktree is on branch $int_branch, cut from main. Bring in the build branch:

    git merge $branch

Resolve every conflict so both main's code and the branch's code survive: keep
all route registrations, module declarations and dependencies from both sides,
and point every user of a moved file (fixtures, paths) at one location. Do not
add features or rewrite logic beyond what the merge needs.

Then run ./check.sh until it exits 0, and commit on $int_branch.
${failure:+
What failed when this branch was merged into main:
$failure
}
When ./check.sh passes, call kanban_complete with a summary of each conflict and
how you resolved it, plus the last 20 lines of ./check.sh. A person merges
$int_branch into main. If a conflict needs a design decision, call kanban_block
with the question instead of guessing.
EOF

id=$(create_task "Integrate: $title" --assignee "$(profile_name planner)" \
  --workspace "worktree:$wt" --branch "$int_branch" --created-by factory \
  --idempotency-key "integrate:$build_id" --body-file "$body_file")
rm -f "$body_file"

notify_discord "$id" planner alerts
log "Integration task $id: $branch -> $int_branch (worktree $wt)"
