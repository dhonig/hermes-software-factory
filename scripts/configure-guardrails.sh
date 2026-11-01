#!/usr/bin/env bash
# Apply the article's guardrails to Hermes's kanban settings.
#
# These keys live in ~/.hermes/config.yaml and apply to every board on this
# machine, not just the factory's. The previous values are saved so
# `factory.sh teardown` can put them back.
. "$(dirname "$0")/../lib/common.sh"

SETTINGS="
kanban.max_in_progress=$MAX_IN_PROGRESS
kanban.max_in_progress_per_profile=$MAX_IN_PROGRESS_PER_PROFILE
kanban.failure_limit=$FAILURE_LIMIT
kanban.auto_decompose=false
kanban.auto_promote_children=false
kanban.auto_subscribe_on_create=false
kanban.review_dispatch=true
"

backup="$STATE_DIR/config-before.txt"
if [ ! -f "$backup" ] && [ "$DRY_RUN" != "1" ]; then
  cp "$(hermes config path)" "$STATE_DIR/config.yaml.bak"
  for kv in $SETTINGS; do
    key=${kv%%=*}
    val=$(hermes config get "$key" 2>/dev/null || true)
    case "$val" in "Config key not set"*) val="" ;; esac
    echo "$key=$val" >> "$backup"
  done
  log "Saved previous values to $backup"
fi

for kv in $SETTINGS; do
  log "Setting ${kv%%=*} = ${kv#*=}"
  run hermes config set "${kv%%=*}" "${kv#*=}"
done

cat <<EOF

Guardrails:
  - at most $MAX_IN_PROGRESS tasks running, one per role
  - a task is blocked after $FAILURE_LIMIT consecutive failures
  - automatic decomposition is off: a person approves every plan
  - completions don't wake agents; only alerts you subscribe to are sent
EOF
