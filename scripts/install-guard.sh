#!/usr/bin/env bash
# Install the factory-guard Hermes plugin (hermes-plugin/factory-guard) and
# enable it. It commits builder work before review, keeps builders from
# reviewing their own tasks, stops reviewer/security/QA from calling
# kanban_request_review, and stops builders from calling kanban_complete. See the plugin's docstring for details.
#
# Plugins load from each Hermes home, so it goes into the default home (where
# the dispatcher runs) and into the reviewer, security, QA, builder and integrator
# profiles (where their workers run).
. "$(dirname "$0")/../lib/common.sh"

src="$FACTORY_ROOT/hermes-plugin/factory-guard"
dest="$HOME/.hermes/plugins/factory-guard"

log "Installing factory-guard plugin to $dest"
run mkdir -p "$dest"
run cp "$src/plugin.yaml" "$src/__init__.py" "$dest/"

enabled=$(hermes config get plugins.enabled --json 2>/dev/null | jq -c 'if type=="array" then . else [] end' 2>/dev/null || echo "[]")
if printf '%s' "$enabled" | jq -e 'index("factory-guard")' >/dev/null; then
  log "factory-guard already enabled"
else
  log "Enabling factory-guard"
  run hermes config set plugins.enabled "$(printf '%s' "$enabled" | jq -c '. + ["factory-guard"]')" >/dev/null
fi
state_add plugins factory-guard

for role in reviewer security qa backend frontend integrator; do
  p=$(profile_name "$role")
  pdest="$HOME/.hermes/profiles/$p/plugins/factory-guard"
  log "Installing factory-guard into $p"
  run mkdir -p "$pdest"
  run cp "$src/plugin.yaml" "$src/__init__.py" "$pdest/"
  [ "$DRY_RUN" = "1" ] || printf '%s\n' "$FACTORY_ROOT" > "$pdest/factory_root"
  penabled=$(hermes -p "$p" config get plugins.enabled --json 2>/dev/null | jq -c 'if type=="array" then . else [] end' 2>/dev/null || echo "[]")
  if ! printf '%s' "$penabled" | jq -e 'index("factory-guard")' >/dev/null; then
    run hermes -p "$p" config set plugins.enabled "$(printf '%s' "$penabled" | jq -c '. + ["factory-guard"]')" >/dev/null
  fi
done
