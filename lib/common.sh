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
BUILDER_MODEL=""
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

# Post a task's outcome (done, blocked) to Discord: in its role's channel, so
# each agent reports where you talk to it, and optionally in #factory-alerts.
#   notify_discord <task-id> <role> [alerts]
notify_discord() {
  local task="$1" role="$2" var chan
  var="DISCORD_CHANNEL_$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')"
  chan=$(eval "printf '%s' \"\${$var:-}\"")
  [ -n "$chan" ] && _subscribe "$task" "$chan"
  [ "${3:-}" = alerts ] && [ -n "$DISCORD_NOTIFY_CHANNEL" ] && _subscribe "$task" "$DISCORD_NOTIFY_CHANNEL"
  return 0
}

_subscribe() {
  local extra=()
  [ -n "$DISCORD_GUILD_ID" ] && extra=(--guild-id "$DISCORD_GUILD_ID")
  local out
  out=$(run kanban notify-subscribe "$1" --platform discord --chat-id "$2" \
    --chat-type channel --delivery-mode notify ${extra[@]+"${extra[@]}"} </dev/null) \
    || { warn "could not subscribe $1 to Discord channel $2"; return 0; }
  [ "$DRY_RUN" = "1" ] && printf '%s\n' "$out"
  return 0
}

# --- Interactive prompts and settings files (used by the Discord scripts) ---

ask() { # ask VAR "prompt" [default]
  local reply
  read -r -p "$2${3:+ [$3]}: " reply
  printf -v "$1" '%s' "${reply:-${3:-}}"
}

# Discord IDs are long numbers (snowflakes), not usernames or #names.
# Right-click a user, server or channel with Developer Mode on to copy one.
ask_ids() { # ask_ids VAR "prompt" required|optional [default]
  local val
  while :; do
    ask val "$2" "${4:-}"
    val=$(printf '%s' "$val" | tr -d ' ')
    if [ -z "$val" ]; then
      [ "$3" = optional ] && break
    elif printf '%s' "$val" | grep -qE '^[0-9]{15,22}(,[0-9]{15,22})*$'; then
      break
    fi
    warn "Expected a numeric Discord ID like 284102345871466496 (right-click > Copy ID)."
  done
  printf -v "$1" '%s' "$val"
}

ENV_FILE="$(hermes config env-path 2>/dev/null || echo "$HOME/.hermes/.env")"

# Write KEY=VALUE into Hermes's .env without putting the value on any command line.
set_env() {
  local key="$1" tmp
  if [ "$DRY_RUN" = "1" ]; then
    printf '%s[dry-run]%s set %s in %s\n' "$C_DIM" "$C_OFF" "$key" "$ENV_FILE"
    return
  fi
  tmp=$(mktemp)
  KEY="$key" awk -F= '$1 != ENVIRON["KEY"]' "$ENV_FILE" > "$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$2" >> "$tmp"
  cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
}

backup_env() {
  [ "$DRY_RUN" = "1" ] && return 0
  touch "$ENV_FILE"
  cp "$ENV_FILE" "$STATE_DIR/env.bak.$(date +%Y%m%d%H%M%S)"
  log "Backed up $ENV_FILE to $STATE_DIR"
}

# Set KEY="value" in factory.conf.
conf_set() {
  local conf="$FACTORY_ROOT/factory.conf"
  if [ "$DRY_RUN" = "1" ]; then
    printf '%s[dry-run]%s set %s=%s in factory.conf\n' "$C_DIM" "$C_OFF" "$1" "$2"
    return
  fi
  [ -f "$conf" ] || cp "$FACTORY_ROOT/factory.conf.example" "$conf"
  grep -v "^$1=" "$conf" > "$conf.tmp" || true
  echo "$1=\"$2\"" >> "$conf.tmp"
  mv "$conf.tmp" "$conf"
}

# gateway.profile_routes as a JSON array ([] when unset).
routes_json() {
  hermes config get gateway.profile_routes --json 2>/dev/null \
    | jq -c 'if type=="array" then . else [] end' 2>/dev/null || echo "[]"
}

# Builders sometimes request review without naming the reviewer, and Hermes then
# hands the review back to the builder, which loops. Send those to the Reviewer.
route_reviews() {
  local reviewer ids id
  reviewer=$(profile_name reviewer)
  ids=$(kanban list --status review --json 2>/dev/null | jq -r --arg b "$(profile_name backend)" --arg f "$(profile_name frontend)" \
    '(if type=="array" then . else .tasks end)[] | select(.assignee==$b or .assignee==$f) | .id' 2>/dev/null || true)
  for id in $ids; do
    log "Task $id is in review with its builder; routing it to $reviewer"
    run kanban request-review "$id" --reviewer "$reviewer" --force \
      --summary "Rerouted to $reviewer: review was requested without a reviewer." >/dev/null </dev/null \
      || warn "could not reroute $id"
  done
}
