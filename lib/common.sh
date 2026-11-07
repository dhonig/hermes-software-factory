# Shared helpers for the factory scripts. Source this; don't run it.
# Written for the bash 3.2 that ships with macOS (no assoc arrays, no mapfile).

set -euo pipefail

FACTORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# FACTORY_STATE_DIR is for tests; the guard plugin reads <root>/.factory/check-pass.
STATE_DIR="${FACTORY_STATE_DIR:-$FACTORY_ROOT/.factory}"
mkdir -p "$STATE_DIR"

# Settings: lib/config.py holds every key and default. It reads factory.toml
# (plus environment overrides for the keys that allow them). Without
# factory.toml, the deprecated factory.conf is sourced over the defaults.
# FACTORY_CONFIG_DIR is for tests: where to look for factory.toml/factory.conf.
CONFIG_DIR="${FACTORY_CONFIG_DIR:-$FACTORY_ROOT}"
_cfg=$(python3 -I "$FACTORY_ROOT/lib/config.py" shell "$CONFIG_DIR") \
  || { printf 'error: bad factory settings (see above); ./factory.sh config show\n' >&2; exit 1; }
eval "$_cfg"
if [ -z "$FACTORY_CONFIG_FILE" ] && [ -f "$CONFIG_DIR/factory.conf" ]; then
  # Read the environment overrides first: sourcing factory.conf would overwrite
  # an exported variable such as CHECK_TIMEOUT before Python could see it.
  _env=$(python3 -I "$FACTORY_ROOT/lib/config.py" env "$CONFIG_DIR") || exit 1
  . "$CONFIG_DIR/factory.conf"
  eval "$_env"   # the environment still wins for the keys that allow it
  unset _env
  FACTORY_CONFIG_FILE=factory.conf
  if [ -z "${FACTORY_CONF_WARNED:-}" ]; then
    printf 'warning: factory.conf is deprecated; run ./factory.sh config migrate to write factory.toml\n' >&2
    export FACTORY_CONF_WARNED=1
  fi
fi
unset _cfg
# Tests point the scripts at a scratch board (with HERMES_KANBAN_HOME).
BOARD="${FACTORY_BOARD:-$BOARD}"
TARGET_REPO="${FACTORY_TARGET_REPO:-$TARGET_REPO}"

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

# Run a command in its own process group under a hard time limit (0 = none).
# Whatever it leaves running is killed when it exits. Exits 124 on timeout.
#   run_limited <seconds> <command> [args...]
run_limited() { "$FACTORY_ROOT/lib/run-limited.pl" "$@"; }

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

# A role prompt with its placeholders filled in: {{FACTORY_SH}} (this factory's
# factory.sh), {{FACTORY_STATE}} (its .factory dir), {{OMLX_PORT}} (the model
# server's port, from models.omlx_url or Hermes's model.base_url).
#   render_role <role>   prints the prompt
render_role() {
  local url port
  url="$OMLX_URL"
  [ -n "$url" ] || url=$(hermes config get model.base_url 2>/dev/null || true)
  port=$(printf '%s' "$url" | sed -nE 's#^[a-z]+://[^/:]+:([0-9]+).*#\1#p')
  [ -n "$port" ] || port=8000
  sed -e "s|{{FACTORY_SH}}|$FACTORY_ROOT/factory.sh|g" -e "s|{{FACTORY_STATE}}|$FACTORY_ROOT/.factory|g" \
    -e "s|{{OMLX_PORT}}|$port|g" "$FACTORY_ROOT/roles/$1.md"
}

# Roles that get work dispatched to them. The security role only runs with
# SECURITY_ROLE=1; by default the check gate's scanners replace it.
active_roles() {
  local r
  for r in $ROLES; do
    [ "$r" = security ] && [ "$SECURITY_ROLE" != 1 ] && continue
    printf '%s\n' "$r"
  done
}

# Refuse to release work to the dispatcher while the model server isn't ready
# (omlx loading a model mid-run crashes workers). FACTORY_SKIP_HEALTH=1 skips it.
require_healthy() {
  [ "${FACTORY_SKIP_HEALTH:-0}" = 1 ] && return 0
  if ! "$FACTORY_ROOT/scripts/health.sh" --quiet; then
    if [ "$DRY_RUN" = 1 ]; then
      warn "model server not ready (would refuse without --dry-run)"
      return 0
    fi
    die "Model server not ready; see ./factory.sh health. Set FACTORY_SKIP_HEALTH=1 to go ahead anyway."
  fi
}

PAUSE_FILE="$STATE_DIR/paused-tasks.txt"

profile_exists() {
  hermes profile list 2>/dev/null | awk '{gsub(/◆/,""); print $1}' | grep -qx "$1"
}

board_exists() {
  hermes kanban boards list 2>/dev/null | awk '{gsub(/●/,""); print $1}' | grep -qx "$BOARD"
}

kanban() { hermes kanban --board "$BOARD" "$@"; }

# The board's SQLite file. HERMES_KANBAN_HOME points scratch boards elsewhere.
kanban_db() { printf '%s/kanban/boards/%s/kanban.db' "${HERMES_KANBAN_HOME:-$HOME/.hermes}" "$BOARD"; }

# Read-only query against the board DB (tab-separated rows). Never writes:
# query_only refuses any write, and mode=ro can't open a WAL DB without sidecars.
kanban_query() {
  sqlite3 -separator "$(printf '\t')" -cmd "PRAGMA query_only = ON" "$(kanban_db)" "$1"
}

require_target_repo() {
  [ -n "$TARGET_REPO" ] || die "TARGET_REPO is not set: copy factory.example.toml to factory.toml and set target.repo."
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

# Create one ticket's tasks: build (own worktree + branch, reviewed by the
# Reviewer) -> [security check, only with SECURITY_ROLE=1] -> QA, in the
# build's worktree. Used by
# approve-plan.sh and ticket.sh. Sets CHAIN_BUILD, CHAIN_SEC, CHAIN_QA, CHAIN_DESC.
#   create_chain <role> <title> <scope> <branch> <worktree> <key> <parent-build|""> <context> <qa-criteria>
create_chain() {
  local role="$1" title="$2" scope="$3" branch="$4" wt="$5" key="$6" parent="$7" context="$8" criteria="$9"
  local reviewer parent_args=()
  reviewer=$(profile_name reviewer)
  [ -n "$parent" ] && parent_args=(--parent "$parent")

  CHAIN_BUILD=$(create_task "$title" --assignee "$(profile_name "$role")" \
    --workspace "worktree:$wt" --branch "$branch" --created-by factory \
    --idempotency-key "$key:build" ${parent_args[@]+"${parent_args[@]}"} \
    --body "$scope

Work in the worktree for branch $branch. Commit your changes on that branch.
When done, call kanban_request_review with reviewer="$reviewer". Always pass the
reviewer; without it you would be asked to review your own work.
$context Shared memory: .ecc/memory/ in the worktree.")

  CHAIN_SEC=""
  local qa_parent="$CHAIN_BUILD"
  if [ "$SECURITY_ROLE" = 1 ]; then
    CHAIN_SEC=$(create_task "Security check: $title" --assignee "$(profile_name security)" \
      --workspace "dir:$wt" --parent "$CHAIN_BUILD" --created-by factory \
      --idempotency-key "$key:security" \
      --body "Security-check the diff of branch $branch against the default branch. Build task: $CHAIN_BUILD.")
    qa_parent="$CHAIN_SEC"
  fi

  CHAIN_QA=$(create_task "QA: $title" --assignee "$(profile_name qa)" \
    --workspace "dir:$wt" --parent "$qa_parent" --created-by factory \
    --idempotency-key "$key:qa" \
    --body "Verify branch $branch end to end. $criteria")

  notify_discord "$CHAIN_BUILD" "$role"
  notify_discord "$CHAIN_BUILD" reviewer      # the Reviewer finishes the build card
  [ -n "$CHAIN_SEC" ] && notify_discord "$CHAIN_SEC" security
  notify_discord "$CHAIN_QA" qa alerts        # "ready to merge" also goes to #factory-alerts
  CHAIN_DESC="build $CHAIN_BUILD -> ${CHAIN_SEC:+security $CHAIN_SEC -> }qa $CHAIN_QA"
}

# Post a task's outcome (done, blocked) to Discord: in its role's channel, so
# each agent reports where you talk to it, and optionally in #factory-alerts.
#   notify_discord <task-id> <role> [alerts]
notify_discord() {
  local task="$1" role="$2" var chan
  var="DISCORD_CHANNEL_$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')"
  chan=$(eval "printf '%s' \"\${$var:-}\"")
  [ -n "$chan" ] && _subscribe "$task" "$chan" "$(profile_name "$role")"
  [ "${3:-}" = alerts ] && [ -n "$DISCORD_NOTIFY_CHANNEL" ] && _subscribe "$task" "$DISCORD_NOTIFY_CHANNEL" default
  return 0
}

# A role channel is routed to its role profile, so that profile must deliver.
_subscribe() { # _subscribe <task> <channel> <notifier-profile>
  local extra=(--notifier-profile "$3")
  [ -n "$DISCORD_GUILD_ID" ] && extra+=(--guild-id "$DISCORD_GUILD_ID")
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

# Set a setting in factory.toml (or, while it's still in use, factory.conf).
#   conf_set <SHELL_VAR> <value>
conf_set() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '%s[dry-run]%s set %s=%s in %s\n' "$C_DIM" "$C_OFF" "$1" "$2" "${FACTORY_CONFIG_FILE:-factory.toml}"
    return
  fi
  if [ "$FACTORY_CONFIG_FILE" != factory.conf ]; then
    python3 -I "$FACTORY_ROOT/lib/config.py" set "$CONFIG_DIR" "$1" "$2"
    return
  fi
  local conf="$CONFIG_DIR/factory.conf"
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
