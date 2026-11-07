#!/usr/bin/env bash
# Undo ./factory.sh pause: release exactly the cards it held, after checking that
# the model server is ready. Cards that were blocked before the pause stay blocked.
#
#   scripts/resume.sh [--force] [--dry-run]
#
# --force resumes even when ./factory.sh health fails.
# The record moves to .factory/paused-tasks.<date>.txt afterwards.
. "$(dirname "$0")/../lib/common.sh"
eval "set -- $(strip_flags "$@")"
force=0
[ "${1:-}" = --force ] && force=1

[ -f "$PAUSE_FILE" ] || die "The factory isn't paused ($PAUSE_FILE doesn't exist)."

if [ "$force" = 1 ]; then
  warn "Skipping the model-server check (--force)."
else
  "$FACTORY_ROOT/scripts/health.sh" || {
    [ "$DRY_RUN" = 1 ] && warn "model server not ready (would refuse without --dry-run)" \
      || die "Model server not ready; nothing resumed. Fix it, or rerun with --force."
  }
fi

reviewer=$(profile_name reviewer)
released=0
# Rows: "<task> <was> <held-by...>". Only rows held by "pause" are ours to release.
while read -r id was held rest; do
  case "$id" in t_*) ;; *) continue ;; esac
  if [ "$held" != pause ]; then
    log "Leaving $id alone ($was, ${held}${rest:+ $rest})"
    continue
  fi
  now=$(kanban_query "select status from tasks where id = '$(printf '%s' "$id" | tr -cd 'a-zA-Z0-9_')'")
  if [ "$now" != scheduled ]; then
    warn "$id is $now now, not scheduled; leaving it as it is"
    continue
  fi
  run kanban unblock "$id" --reason "Factory resumed" >/dev/null </dev/null || { warn "could not release $id"; continue; }
  if [ "$was" = review ]; then
    run kanban request-review "$id" --force --reviewer "$reviewer" \
      --summary "Review paused by factory.sh pause and resumed; review as usual." >/dev/null </dev/null \
      || warn "$id is released but not back in review: hand it to $reviewer by hand"
  fi
  log "Released $id (was $was)"
  released=$((released + 1))
done < "$PAUSE_FILE"

if [ "$DRY_RUN" = 1 ]; then
  log "[dry-run] would release $released card(s) and archive $PAUSE_FILE"
  exit 0
fi
mv "$PAUSE_FILE" "$STATE_DIR/paused-tasks.$(date +%Y%m%d%H%M%S).txt"
log "Factory resumed: $released card(s) released."
