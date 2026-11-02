#!/usr/bin/env bash
# Install the factory-guard Hermes plugin (hermes-plugin/factory-guard) and
# enable it. It commits builder work before review and keeps builders from
# reviewing their own tasks. See the plugin's docstring for details.
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
