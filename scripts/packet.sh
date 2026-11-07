#!/usr/bin/env bash
# Write a review packet for a ticket whose QA passed: everything the person (or
# Claude) merging it needs, in one file, without digging through cards and logs.
#
#   scripts/packet.sh <build-or-qa-task-id> [--pr] [--dry-run]
#
# Writes .factory/review/<build-task>.md with the ticket, branch, diff stat,
# commits, whether it merges cleanly into main (git merge-tree, which touches
# no working tree), the check gate's record for the branch head, and the
# Reviewer's and QA's summaries (QA's includes the smoke output).
#
# --pr also pushes the branch and opens a draft PR with the packet as its body.
# Only when the target repo has a GitHub remote and gh is logged in; never
# under --dry-run. Agents never push: this is for a person to run.
. "$(dirname "$0")/../lib/common.sh"
eval "set -- $(strip_flags "$@")"
require_target_repo

[ $# -ge 1 ] || die "usage: packet.sh <build-or-qa-task-id> [--pr]"
id=$(printf '%s' "$1" | tr -cd 'a-zA-Z0-9_')
pr=0
[ "${2:-}" = --pr ] && pr=1
[ -f "$(kanban_db)" ] || die "No board database at $(kanban_db)"

q() { kanban_query "$1"; }
ws=$(q "select workspace_path from tasks where id = '$id'")
[ -n "$ws" ] || die "No task $id on board $BOARD (or it has no worktree)."
build=$(q "select id from tasks where workspace_path = '$(printf '%s' "$ws" | sed "s/'/''/g")'
  and workspace_kind = 'worktree' order by created_at desc limit 1")
[ -n "$build" ] || die "No build task found for worktree $ws."
qa=$(q "select id from tasks where workspace_path = '$(printf '%s' "$ws" | sed "s/'/''/g")'
  and assignee like '%qa' and workspace_kind = 'dir' order by created_at desc limit 1")

title=$(q "select title from tasks where id = '$build'")
branch=$(q "select branch_name from tasks where id = '$build'")
[ -n "$branch" ] || die "Build task $build has no branch."
git -C "$TARGET_REPO" rev-parse -q --verify "refs/heads/$branch" >/dev/null \
  || die "Branch $branch isn't in $TARGET_REPO (already merged and deleted?)."
head=$(git -C "$TARGET_REPO" rev-parse "refs/heads/$branch")
base="${PACKET_BASE:-main}"

# Latest summary a profile left on a task (run summary, else the task result).
summary() { # summary <task> <profile-suffix>
  [ -n "$1" ] || return 0
  local s
  s=$(q "select summary from task_runs where task_id = '$1' and profile like '%$2'
    and summary is not null and summary != '' order by id desc limit 1")
  [ -n "$s" ] || s=$(q "select coalesce(result, '') from tasks where id = '$1'")
  printf '%s\n' "${s:-(none recorded)}"
}

check_line() {
  local name f
  name=$(basename "$ws")
  for f in "$STATE_DIR/check-pass/$head@$name" "$STATE_DIR/check-pass/$head"; do
    if [ -f "$f" ]; then
      printf 'Passed on %s at %s (recorded by factory.sh check%s).\n' "${head:0:12}" "$(cat "$f")" \
        "$(case "$f" in *@*) echo ', including the ticket done-when' ;; esac)"
      return
    fi
  done
  printf '**No pass recorded for the branch head %s.** Run `./factory.sh check %s` before merging.\n' "${head:0:12}" "$ws"
}

merge_line() {
  local out
  if git -C "$TARGET_REPO" merge-base --is-ancestor "refs/heads/$branch" "$base"; then
    printf 'Already merged into %s: nothing to do.\n' "$base"
  elif out=$(git -C "$TARGET_REPO" merge-tree --write-tree --name-only "$base" "refs/heads/$branch" 2>/dev/null); then
    printf 'Merges cleanly into %s.\n' "$base"
  else
    printf '**Conflicts with %s** in:\n\n' "$base"
    printf '%s\n' "$out" | sed -n '2,/^$/p' | sed '/^$/d; s/^/- /'
    printf '\nHand it to the Integrator: `./factory.sh integrate %s`\n' "$build"
  fi
}

done_file="$STATE_DIR/done-when/$(basename "$ws")"
out="$STATE_DIR/review/$build.md"
render() {
  cat <<EOF
# Review packet: $title

| | |
|---|---|
| Build task | \`$build\` |
| QA task | \`${qa:-none}\` |
| Branch | \`$branch\` at \`${head:0:12}\` |
| Worktree | \`$ws\` |
| Repository | \`$TARGET_REPO\` |
| Written | $(date '+%Y-%m-%d %H:%M %Z') |

## Ticket

$(q "select coalesce(body, '') from tasks where id = '$build'" | sed '/^Work in the worktree for branch/,$d')
EOF
  [ -f "$done_file" ] && printf '\n**Done when:** `%s` exits 0 (enforced by the check gate).\n' "$(cat "$done_file")"
  cat <<EOF

## Check gate

$(check_line)

## Merge with $base

$(merge_line)

## Diff stat ($base...$branch)

\`\`\`
$(git -C "$TARGET_REPO" diff --stat "$base...refs/heads/$branch")
\`\`\`

## Commits

\`\`\`
$(git -C "$TARGET_REPO" log --oneline --no-decorate "$base..refs/heads/$branch")
\`\`\`

## Reviewer

$(summary "$build" reviewer)

## QA (includes the smoke test output)

$(summary "$qa" qa)

---
Merge: \`git -C $TARGET_REPO merge --no-ff $branch\`
EOF
}

if [ "$DRY_RUN" = 1 ]; then
  log "[dry-run] would write $out:"
  render | sed 's/^/  /'
else
  mkdir -p "$STATE_DIR/review"
  render > "$out"
  log "Review packet: $out"
fi

[ "$pr" = 1 ] || exit 0
written="The packet is written to $out"
[ "$DRY_RUN" = 1 ] && written="(dry-run: nothing written)"
remote=$(git -C "$TARGET_REPO" remote get-url origin 2>/dev/null || true)
case "$remote" in
  *github.com[:/]*) ;;
  *) die "--pr needs a GitHub 'origin' remote in $TARGET_REPO (found: ${remote:-none}). $written; open the PR by hand." ;;
esac
gh auth status >/dev/null 2>&1 || die "--pr needs gh to be logged in (gh auth login). $written."
if [ "$DRY_RUN" = 1 ]; then
  run git -C "$TARGET_REPO" push -u origin "$branch"
  run gh pr create --repo "$remote" --draft --base "$base" --head "$branch" --title "$title" --body-file "$out"
  exit 0
fi
git -C "$TARGET_REPO" push -u origin "$branch"
(cd "$TARGET_REPO" && gh pr create --draft --base "$base" --head "$branch" --title "$title" --body-file "$out")
