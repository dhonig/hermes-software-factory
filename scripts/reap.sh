#!/usr/bin/env bash
# Kill processes left running inside task worktrees: `trunk serve`, debug
# backends, test servers a worker started and never stopped.
#
#   scripts/reap.sh [<worktree-path>...] [--force] [--dry-run]
#
# With no paths it looks in every worktree that belongs to a task on the board
# (its workspace_path), never in other worktrees such as a manual review checkout.
# A process counts as "inside" when its working directory is in the path.
# Live kanban workers (worker_pid of a running task) and everything they
# started are skipped unless --force: blocking or pausing the task stops them.
# --dry-run lists what would be killed.
. "$(dirname "$0")/../lib/common.sh"
eval "set -- $(strip_flags "$@")"

force=0; paths=()
for a in "$@"; do
  case "$a" in
    --force) force=1 ;;
    -*) die "unknown option: $a" ;;
    *) paths+=("$(cd "$a" 2>/dev/null && pwd -P)") || die "No such directory: $a" ;;
  esac
done
if [ ${#paths[@]} -eq 0 ]; then
  [ -f "$(kanban_db)" ] || die "No board database at $(kanban_db)"
  while IFS= read -r w; do
    case "$w" in */.worktrees/*) ;; *) continue ;; esac  # task worktrees only
    [ -d "$w" ] && paths+=("$(cd "$w" && pwd -P)")
  done <<EOF
$(kanban_query "select distinct workspace_path from tasks where workspace_kind in ('worktree', 'dir') and workspace_path is not null")
EOF
  [ ${#paths[@]} -gt 0 ] || { log "No task worktrees on board $BOARD; nothing to reap."; exit 0; }
fi

# Processes to leave alone: this script's own ancestry, and live workers.
protect="$$"
p=$$
while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  [ -n "$p" ] && protect="$protect $p"
done
workers=""
if [ "$force" = 0 ] && [ -f "$(kanban_db)" ]; then
  workers=$(kanban_query "select worker_pid from tasks where status = 'running' and worker_pid is not null" | tr '\n' ' ')
fi

# pid -> ppid for every process, to skip anything a live worker started.
ptree=$(ps -A -o pid=,ppid=)
under_worker() {
  local p="$1" w
  [ -z "$workers" ] && return 1
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    for w in $workers; do [ "$p" = "$w" ] && return 0; done
    p=$(printf '%s\n' "$ptree" | awk -v p="$p" '$1 == p {print $2; exit}')
  done
  return 1
}

# lsof -Fpn prints "p<pid>" then "n<cwd>" for each process.
candidates=$(lsof -w -d cwd -Fpn 2>/dev/null | awk '
  /^p/ { pid = substr($0, 2) }
  /^n/ { print pid "\t" substr($0, 2) }')

victims=""
for root in "${paths[@]}"; do
  while IFS="$(printf '\t')" read -r pid cwd; do
    [ -z "$pid" ] && continue
    case "$cwd/" in "$root"/*) ;; *) continue ;; esac
    case " $protect " in *" $pid "*) continue ;; esac
    if under_worker "$pid"; then
      warn "skipping pid $pid (part of a running kanban worker; use --force to kill it): $(ps -o command= -p "$pid" | cut -c1-100)"
      continue
    fi
    case " $victims " in *" $pid "*) continue ;; esac
    victims="$victims $pid"
    printf '  %s  %s  %s\n' "$pid" "$cwd" "$(ps -o command= -p "$pid" 2>/dev/null | cut -c1-100)"
  done <<EOF
$candidates
EOF
done

[ -z "$victims" ] && { log "No leftover processes in ${#paths[@]} worktree(s)."; exit 0; }
if [ "$DRY_RUN" = 1 ]; then
  log "[dry-run] would stop:$victims"
  exit 0
fi
log "Stopping:$victims"
# shellcheck disable=SC2086
kill -TERM $victims 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  alive=""
  for v in $victims; do kill -0 "$v" 2>/dev/null && alive="$alive $v"; done
  [ -z "$alive" ] && break
  sleep 0.5
done
if [ -n "$alive" ]; then
  warn "Still running after TERM, sending KILL:$alive"
  # shellcheck disable=SC2086
  kill -KILL $alive 2>/dev/null || true
fi
log "Reaped$victims"
