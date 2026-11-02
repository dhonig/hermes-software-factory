#!/usr/bin/env bash
# Connect Hermes's gateway to Discord as the factory's control panel.
# Interactive: you paste the bot token yourself; it is never echoed or logged.
. "$(dirname "$0")/../lib/common.sh"

ENV_FILE="$(hermes config env-path)"
CONF="$FACTORY_ROOT/factory.conf"

cat <<'EOF'
Before you continue, in https://discord.com/developers/applications:
  1. Bot tab: Reset Token and copy it.
  2. Bot tab: turn on Message Content Intent and Server Members Intent. Save.
  3. Invite the bot to your server (OAuth2 URL with scopes bot + applications.commands).
  4. In Discord, User Settings > Advanced > Developer Mode on. The prompts below
     want numeric IDs (right-click > Copy ID), not names.
  5. Create a #factory-alerts channel, plus one channel per role if you want them
     (#planner #backend #frontend #reviewer #security #qa).

EOF

ask() { # ask VAR "prompt" [default]
  local reply
  read -r -p "$2${3:+ [$3]}: " reply
  printf -v "$1" '%s' "${reply:-${3:-}}"
}

# Discord IDs are long numbers (snowflakes), not usernames or #names.
# Right-click a user, server or channel with Developer Mode on to copy one.
ask_ids() { # ask_ids VAR "prompt" required|optional
  local val
  while :; do
    ask val "$2"
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

existing_token=0
grep -q '^DISCORD_BOT_TOKEN=.' "$ENV_FILE" 2>/dev/null && existing_token=1
if [ "$existing_token" = 1 ]; then
  read -r -p "A Discord bot token is already set. Replace it? [y/N]: " yn
  [ "$yn" = y ] || [ "$yn" = Y ] && existing_token=0
fi
token=""
if [ "$existing_token" = 0 ]; then
  read -r -s -p "Bot token (input hidden): " token; echo
  [ -n "$token" ] || die "No token entered."
fi

ask_ids user_id   "Your Discord user ID (number; right-click your name > Copy User ID)" required
ask_ids guild_id  "Server ID (right-click the server icon > Copy Server ID)" required
ask_ids alerts_id "#factory-alerts channel ID (right-click the channel > Copy Channel ID)" required
ask_ids role_ids  "Role channel IDs, comma-separated (optional, Enter to skip)" optional

allowed="$alerts_id${role_ids:+,$role_ids}"

# Write KEY=VALUE into .env without putting the value on any command line.
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

if [ "$DRY_RUN" != "1" ]; then
  touch "$ENV_FILE"
  cp "$ENV_FILE" "$STATE_DIR/env.bak.$(date +%Y%m%d%H%M%S)"
  log "Backed up $ENV_FILE to $STATE_DIR"
fi

[ -n "$token" ] && set_env DISCORD_BOT_TOKEN "$token"
token=""
set_env DISCORD_ALLOWED_USERS "$user_id"     # only you can command the bots
set_env DISCORD_ALLOWED_CHANNELS "$allowed"   # and only in factory channels
set_env DISCORD_REQUIRE_MENTION true          # answer only when @mentioned
set_env DISCORD_IGNORE_NO_MENTION true
set_env DISCORD_ALLOW_BOTS none               # bots never trigger each other
set_env DISCORD_ALLOW_MENTION_EVERYONE false
set_env DISCORD_HOME_CHANNEL "$alerts_id"
set_env DISCORD_HOME_CHANNEL_NAME factory-alerts
state_add discord configured

# Remember the alert channel for task subscriptions.
if [ "$DRY_RUN" != "1" ]; then
  [ -f "$CONF" ] || cp "$FACTORY_ROOT/factory.conf.example" "$CONF"
  for kv in "DISCORD_NOTIFY_CHANNEL=$alerts_id" "DISCORD_GUILD_ID=$guild_id"; do
    k=${kv%%=*}
    grep -v "^$k=" "$CONF" > "$CONF.tmp" || true
    echo "$k=\"${kv#*=}\"" >> "$CONF.tmp"
    mv "$CONF.tmp" "$CONF"
  done
fi

log "Restarting the gateway"
run hermes gateway restart
log "Done. In #factory-alerts, @mention the bot with 'hello' to test it."
