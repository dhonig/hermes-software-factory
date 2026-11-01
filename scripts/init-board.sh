#!/usr/bin/env bash
# Create the factory's own kanban board. Other boards are left alone.
. "$(dirname "$0")/../lib/common.sh"
require_target_repo

run hermes kanban init >/dev/null
if board_exists; then
  log "Board '$BOARD' already exists."
else
  log "Creating board '$BOARD'"
  run hermes kanban boards create "$BOARD" --name "$BOARD_NAME" \
    --description "Planner -> builders -> reviewer -> security -> QA" \
    --default-workdir "$TARGET_REPO"
  state_add boards "$BOARD"
fi
