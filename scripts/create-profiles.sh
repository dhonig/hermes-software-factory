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
    integrator) echo "Resolves merge conflicts for branches that do not merge cleanly into main. No features." ;;
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

# The Planner plans; it never touches code. Workers run with the profile's
# CLI toolsets, so removing these there removes them from kanban runs too.
log "Removing code-editing tools from $(profile_name planner)"
run hermes -p "$(profile_name planner)" tools disable --platform cli terminal file code_execution delegation

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

# The Integrator edits Rust to resolve merges, so it also gets the coder model
# (INTEGRATOR_MODEL, defaulting to BUILDER_MODEL), and no sub-agents.
log "Removing delegation tools from $(profile_name integrator)"
run hermes -p "$(profile_name integrator)" tools disable --platform cli code_execution delegation
integrator_model="${INTEGRATOR_MODEL:-$BUILDER_MODEL}"
if [ -n "$integrator_model" ]; then
  log "Setting $(profile_name integrator) model to $integrator_model"
  run hermes -p "$(profile_name integrator)" config set model.default "$integrator_model" >/dev/null
fi
