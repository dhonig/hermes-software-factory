# Shared helpers for the factory scripts. Source this; don't run it.
# Written for the bash 3.2 that ships with macOS (no assoc arrays, no mapfile).

set -euo pipefail

FACTORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$FACTORY_ROOT/.factory"
mkdir -p "$STATE_DIR"

# Defaults, overridden by factory.conf.
BOARD="software-factory"
BOARD_NAME="Software Factory"
PROFILE_PREFIX="sf-"
ROLES="planner backend frontend reviewer security qa"
TARGET_REPO=""
MAX_IN_PROGRESS=2
MAX_IN_PROGRESS_PER_PROFILE=1
FAILURE_LIMIT=2
DISCORD_NOTIFY_CHANNEL=""
DISCORD_GUILD_ID=""

[ -f "$FACTORY_ROOT/factory.conf" ] && . "$FACTORY_ROOT/factory.conf"

DRY_RUN="${DRY_RUN:-0}"
for _arg in "$@"; do
  [ "$_arg" = "--dry-run" ] && DRY_RUN=1
done
unset _arg

if [ -t 1 ]; then
  C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_OFF=$'\033[0m'
else
  C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_OFF=""
fi

log()  { printf '%s==>%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%swarn:%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

# Run a command, or just print it under --dry-run.
run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '%s[dry-run]%s' "$C_DIM" "$C_OFF"
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

# Strip --dry-run from an argument list so scripts can parse the rest.
# Usage: eval "set -- $(strip_flags "$@")"
strip_flags() {
  local a
  for a in "$@"; do
    [ "$a" = "--dry-run" ] && continue
    printf '%q ' "$a"
  done
}

profile_name() { printf '%s%s' "$PROFILE_PREFIX" "$1"; }

profile_exists() {
  hermes profile list 2>/dev/null | awk '{gsub(/◆/,""); print $1}' | grep -qx "$1"
}

board_exists() {
  hermes kanban boards list 2>/dev/null | awk '{gsub(/●/,""); print $1}' | grep -qx "$BOARD"
}

kanban() { hermes kanban --board "$BOARD" "$@"; }

require_target_repo() {
  [ -n "$TARGET_REPO" ] || die "TARGET_REPO is not set. Copy factory.conf.example to factory.conf and set it."
  TARGET_REPO="${TARGET_REPO/#\~/$HOME}"
  [ -d "$TARGET_REPO/.git" ] || die "TARGET_REPO ($TARGET_REPO) is not a git repository."
  # Hermes only creates worktrees at paths inside the repo, so they live in
  # <repo>/.worktrees (git-ignored by memory-init.sh).
  WORKTREE_ROOT="$TARGET_REPO/.worktrees"
}

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40
}

# Record something this factory created so teardown only removes its own work.
state_add() { [ "$DRY_RUN" = "1" ] && return 0; grep -qxF "$2" "$STATE_DIR/$1" 2>/dev/null || echo "$2" >> "$STATE_DIR/$1"; }

# Create a task and print its id. Extra args go straight to `kanban create`.
create_task() {
  if [ "$DRY_RUN" = "1" ]; then
    run hermes kanban --board "$BOARD" create "$@" --json >&2
    echo "t_dryrun$RANDOM"
    return
  fi
  kanban create "$@" --json </dev/null | jq -r '.id // .task.id'
}

# Subscribe a task to the Discord alerts channel (passive, terminal events only).
notify_discord() {
  [ -n "$DISCORD_NOTIFY_CHANNEL" ] || return 0
  local extra=()
  [ -n "$DISCORD_GUILD_ID" ] && extra=(--guild-id "$DISCORD_GUILD_ID")
  run kanban notify-subscribe "$1" --platform discord --chat-id "$DISCORD_NOTIFY_CHANNEL" \
    --chat-type channel --delivery-mode notify ${extra[@]+"${extra[@]}"} >/dev/null || \
    warn "could not subscribe $1 to Discord notifications"
}
