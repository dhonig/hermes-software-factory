#!/usr/bin/env bash
# Undo what these scripts set up: archive the factory board, delete the role
# profiles they created, and restore the previous kanban settings.
# Discord settings in ~/.hermes/.env are left in place (a backup is in .factory/).
# Task worktrees and branches in the target repo are left for you to merge or
# remove (`hermes worktree` can reclaim merged ones).
. "$(dirname "$0")/../lib/common.sh"

if [ "$DRY_RUN" != 1 ]; then
  read -r -p "Archive board '$BOARD', delete factory profiles and restore kanban settings? [y/N]: " ans
  [ "$ans" = y ] || [ "$ans" = Y ] || exit 0
fi

if [ -f "$STATE_DIR/boards" ]; then
  while IFS= read -r b; do
    log "Archiving board $b"
    run hermes kanban boards rm "$b" </dev/null || warn "could not archive $b"
  done < "$STATE_DIR/boards"
fi

if [ -f "$STATE_DIR/profiles" ]; then
  while IFS= read -r p; do
    log "Deleting profile $p"
    run hermes profile delete "$p" </dev/null || warn "could not delete $p"
  done < "$STATE_DIR/profiles"
fi

if grep -qx routes "$STATE_DIR/discord" 2>/dev/null; then
  log "Removing role-channel routes"
  routes=$(routes_json | jq -c --arg p "$PROFILE_PREFIX" '[.[] | select((.name // "") | startswith($p) | not)]')
  run hermes config set gateway.profile_routes "$routes" >/dev/null
fi

if [ -f "$STATE_DIR/config-before.txt" ]; then
  while IFS= read -r kv; do
    k=${kv%%=*}; v=${kv#*=}
    if [ -z "$v" ] || [ "$v" = None ] || [ "$v" = null ]; then
      log "Unsetting $k"; run hermes config unset "$k" >/dev/null || true
    else
      log "Restoring $k = $v"; run hermes config set "$k" "$v" >/dev/null
    fi
  done < "$STATE_DIR/config-before.txt"
fi

if [ "$DRY_RUN" != 1 ]; then
  rm -f "$STATE_DIR/boards" "$STATE_DIR/profiles" "$STATE_DIR/config-before.txt"
fi
log "Teardown complete."
