#!/usr/bin/env bash
# Connect Hermes's gateway to Discord as the factory's control panel.
# Interactive: you paste the bot token yourself; it is never echoed or logged.
. "$(dirname "$0")/../lib/common.sh"

cat <<'EOF'
Before you continue, in https://discord.com/developers/applications:
  1. Bot tab: Reset Token and copy it.
  2. Bot tab: turn on Message Content Intent and Server Members Intent. Save.
  3. Invite the bot to your server (OAuth2 URL with scopes bot + applications.commands).
  4. In Discord, User Settings > Advanced > Developer Mode on. The prompts below
     want numeric IDs (right-click > Copy ID), not names.
  5. Create a #factory-alerts channel and one channel per role:
     #planner #backend #frontend #reviewer #security #qa

EOF

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

backup_env

[ -n "$token" ] && set_env DISCORD_BOT_TOKEN "$token"
token=""
set_env DISCORD_ALLOWED_USERS "$user_id"     # only you can command the bots
set_env DISCORD_ALLOWED_CHANNELS "$alerts_id" # role channels are added by discord-roles.sh
set_env DISCORD_REQUIRE_MENTION true          # answer only when @mentioned
set_env DISCORD_IGNORE_NO_MENTION true
set_env DISCORD_ALLOW_BOTS none               # bots never trigger each other
set_env DISCORD_ALLOW_MENTION_EVERYONE false
set_env DISCORD_HOME_CHANNEL "$alerts_id"
set_env DISCORD_HOME_CHANNEL_NAME factory-alerts
state_add discord configured

# Remember the alert channel for task subscriptions.
conf_set DISCORD_NOTIFY_CHANNEL "$alerts_id"
conf_set DISCORD_GUILD_ID "$guild_id"

log "Next: one channel per role."
exec "$(dirname "$0")/discord-roles.sh" "$@"
