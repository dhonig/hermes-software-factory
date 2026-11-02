#!/usr/bin/env bash
# Give each role its own Discord channel. One bot serves them all: Hermes's
# gateway.profile_routes sends each channel's messages to that role's profile,
# so @mentioning the bot in #reviewer talks to sf-reviewer, and so on.
# #factory-alerts stays on the default profile. Safe to rerun; Enter keeps
# the current channel.
. "$(dirname "$0")/../lib/common.sh"

[ -n "$DISCORD_GUILD_ID" ] && [ -n "$DISCORD_NOTIFY_CHANNEL" ] \
  || die "Run ./factory.sh discord first (needs the server and #factory-alerts IDs)."

echo "Paste each role channel's ID (right-click the channel > Copy Channel ID)."
routes="[]"
allowed="$DISCORD_NOTIFY_CHANNEL"
for role in $ROLES; do
  var="DISCORD_CHANNEL_$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')"
  current=$(eval "printf '%s' \"\${$var:-}\"")
  ask_ids id "#$role channel ID" required "$current"
  conf_set "$var" "$id"
  allowed="$allowed,$id"
  routes=$(printf '%s' "$routes" | jq -c --arg n "$(profile_name "$role")" --arg g "$DISCORD_GUILD_ID" --arg c "$id" \
    '. + [{name: $n, platform: "discord", guild_id: $g, chat_id: $c, profile: $n}]')
done

# Keep any routes that aren't the factory's own.
existing=$(hermes config get gateway.profile_routes 2>/dev/null | jq -c 'if type=="array" then . else [] end' 2>/dev/null || echo "[]")
merged=$(jq -cn --argjson old "$existing" --argjson new "$routes" --arg p "$PROFILE_PREFIX" \
  '[$old[] | select((.name // "") | startswith($p) | not)] + $new')

backup_env
set_env DISCORD_ALLOWED_CHANNELS "$allowed"
log "Routing role channels to role profiles"
run hermes config set gateway.multiplex_profiles true >/dev/null
run hermes config set gateway.profile_routes "$merged"
state_add discord routes

log "Restarting the gateway"
run hermes gateway restart
cat <<EOF

Done. Test each agent by @mentioning the bot in its channel, for example in
#planner: "@bot who are you?" Each one should answer as its role.
EOF
