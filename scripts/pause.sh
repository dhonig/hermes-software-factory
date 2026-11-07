#!/usr/bin/env bash
# Pause the factory without losing anyone's place: hold every card that could
# start a worker, record what each was doing in .factory/paused-tasks.txt, and
# stop the workers and leftover processes. ./factory.sh resume undoes exactly this.
#
#   scripts/pause.sh ["reason"] [--dry-run]
#
# How cards are held:
#   todo, ready, running  -> `kanban schedule` (parked, not dispatchable). Not
#                            `block`: Hermes sends a card to triage the second
#                            time it is blocked for the same reason.
#   review                -> `kanban reopen-review`, then schedule. Resume puts it
#                            back in review with the Reviewer.
#   blocked, triage, done -> left alone, listed as untouched. Resume never
#                            unblocks them.
. "$(dirname "$0")/../lib/common.sh"
eval "set -- $(strip_flags "$@")"
reason="${1:-paused with factory.sh pause}"

[ -f "$(kanban_db)" ] || die "No board database at $(kanban_db)"
if [ -f "$PAUSE_FILE" ]; then
  die "The factory is already paused (see $PAUSE_FILE). Run ./factory.sh resume first."
fi

rows=$(kanban_query "select id, status, coalesce(worker_pid, ''), title from tasks
  where status in ('todo', 'ready', 'running', 'review', 'blocked', 'triage') order by created_at")
[ -n "$rows" ] || { log "Nothing on board $BOARD to pause."; exit 0; }

tab="$(printf '\t')"
record="$STATE_DIR/paused-tasks.txt.new"
{
  echo "# Factory paused $(date '+%Y-%m-%d %H:%M %Z') with factory.sh pause. Board: $BOARD."
  echo "# Reason: $reason"
  echo "# Resume with: ./factory.sh resume (only rows held by 'pause' are released)."
  printf '# %-12s %-9s %s\n' task was held-by
} > "$record"

pids=""
while IFS="$tab" read -r id status pid title; do
  [ -z "$id" ] && continue
  case "$status" in
    blocked|triage)
      printf '%-14s %-9s %s\n' "$id" "$status" "untouched ($status before the pause)" >> "$record"
      log "$id stays $status: $title"
      continue ;;
    review)
      run kanban reopen-review "$id" --reason "Factory paused: $reason" >/dev/null </dev/null \
        || { warn "could not reopen review of $id; it may still be reviewed"; continue; } ;;
  esac
  if run kanban schedule "$id" "Factory paused: $reason" >/dev/null </dev/null; then
    printf '%-14s %-9s %s\n' "$id" "$status" pause >> "$record"
    log "Held $id (was $status): $title"
    [ -n "$pid" ] && pids="$pids $pid"
  else
    warn "could not hold $id ($status); it may still be dispatched"
  fi
done <<EOF
$rows
EOF

if [ "$DRY_RUN" = 1 ]; then
  echo; sed 's/^/  /' "$record"; rm -f "$record"
  "$FACTORY_ROOT/scripts/reap.sh" --dry-run
  exit 0
fi
mv "$record" "$PAUSE_FILE"

# Scheduling a running card ends its run but leaves the worker process alive.
for pid in $pids; do
  case "$(ps -o command= -p "$pid" 2>/dev/null)" in
    *hermes*) log "Stopping worker $pid"; kill -TERM "$pid" 2>/dev/null || true ;;
  esac
done
[ -n "$pids" ] && sleep 3
"$FACTORY_ROOT/scripts/reap.sh" || warn "reap failed; check ./factory.sh reap --dry-run"
log "Factory paused. Record: $PAUSE_FILE. Resume with ./factory.sh resume"
