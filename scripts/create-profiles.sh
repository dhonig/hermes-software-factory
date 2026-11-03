#!/usr/bin/env bash
# Create one Hermes profile per role, each with its own SOUL.md role prompt.
# Profiles clone the default profile's model and keys, but not its messaging
# channels, so only the default gateway talks to Discord.
. "$(dirname "$0")/../lib/common.sh"

describe() {
  case "$1" in
    planner)  echo "Breaks a feature request into small backend/frontend build tasks. Never writes code." ;;
    backend)  echo "Builds server-side code, APIs, data and migrations in an isolated git worktree." ;;
    frontend) echo "Builds UI and client-side code in an isolated git worktree." ;;
    reviewer) echo "Independent code reviewer. Approves or requests changes with concrete reasons." ;;
    security) echo "Independent security check of a branch's diff: injection, secrets, deps, unsafe defaults." ;;
    qa)       echo "Runs tests and exercises the feature end to end before a human merges." ;;
  esac
}

for role in $ROLES; do
  p=$(profile_name "$role")
  if profile_exists "$p"; then
    log "Profile $p already exists; refreshing its role prompt."
  else
    log "Creating profile $p"
    run hermes profile create "$p" --clone-from default --no-alias --description "$(describe "$role")"
    state_add profiles "$p"
  fi

  home="$HOME/.hermes/profiles/$p"
  if [ "$DRY_RUN" = "1" ]; then
    run cp "$FACTORY_ROOT/roles/$role.md" "$home/SOUL.md"
  else
    [ -d "$home" ] || home="$(hermes profile show "$p" | awk '/^Path:/ {print $2}')"
    cp "$FACTORY_ROOT/roles/$role.md" "$home/SOUL.md"
  fi
done

# The Planner plans and, in integration tasks, resolves merge conflicts, so it
# keeps the terminal and file tools. Toolsets are per profile and platform, not
# per task, so its role prompt limits code edits to integration tasks.
log "Setting $(profile_name planner) tools (terminal+file for integration tasks)"
run hermes -p "$(profile_name planner)" tools disable --platform cli code_execution delegation
run hermes -p "$(profile_name planner)" tools enable --platform cli terminal file

# Reviewer, Security and QA judge the work; they don't change it. They keep the
# terminal to read diffs and run tests, but lose the file-editing tools.
for role in reviewer security qa; do
  log "Removing file-editing tools from $(profile_name "$role")"
  run hermes -p "$(profile_name "$role")" tools disable --platform cli file code_execution delegation
done

# Builders write the code, so they get the strongest model you have.
if [ -n "$BUILDER_MODEL" ]; then
  for role in backend frontend; do
    log "Setting $(profile_name "$role") model to $BUILDER_MODEL"
    run hermes -p "$(profile_name "$role")" config set model.default "$BUILDER_MODEL" >/dev/null
  done
fi
