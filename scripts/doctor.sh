#!/usr/bin/env bash
# Check that everything the factory needs is installed and configured.
. "$(dirname "$0")/../lib/common.sh"

fail=0
check() {
  if eval "$2" >/dev/null 2>&1; then
    printf '  %sok%s    %s\n' "$C_GRN" "$C_OFF" "$1"
  else
    printf '  %sFAIL%s  %s\n' "$C_RED" "$C_OFF" "$1"
    [ -n "${3:-}" ] && printf '        %s\n' "$3"
    fail=1
  fi
}

log "Tools"
check "hermes installed" "command -v hermes" "Install Hermes: https://hermes-agent.nousresearch.com"
check "git installed" "command -v git"
check "jq installed" "command -v jq" "brew install jq"

log "Security scanners (optional; the check gate skips missing ones)"
for sc in $(printf '%s' "$SCANNERS" | tr ',' ' '); do
  if command -v "$sc" >/dev/null 2>&1; then
    printf '  %sok%s    %s installed\n' "$C_GRN" "$C_OFF" "$sc"
  else
    printf '  %swarn%s  %s not installed: brew install %s\n' "$C_YEL" "$C_OFF" "$sc" "$sc"
  fi
done
[ -n "$SCANNERS" ] || printf '  %swarn%s  SCANNERS is empty: no secret or code scan in the check gate\n' "$C_YEL" "$C_OFF"
[ "$SECURITY_ROLE" = 1 ] && printf '  info  SECURITY_ROLE=1: the sf-security model role also checks every ticket\n'

log "Factory config"
check "settings file (${FACTORY_CONFIG_FILE:-none})" "[ -n '$FACTORY_CONFIG_FILE' ]" "cp factory.example.toml factory.toml"
[ "$FACTORY_CONFIG_FILE" = factory.conf ] && printf '  %swarn%s  factory.conf is deprecated: ./factory.sh config migrate\n' "$C_YEL" "$C_OFF"
if [ -n "$TARGET_REPO" ]; then
  repo="${TARGET_REPO/#\~/$HOME}"
  check "TARGET_REPO is a git repo ($repo)" "[ -d '$repo/.git' ]"
  check "TARGET_REPO has no uncommitted changes" "[ -z \"\$(git -C '$repo' status --porcelain)\" ]" \
    "Commit or stash first, so task worktrees branch from a known state."
else
  check "TARGET_REPO set" "false" "Set target.repo in factory.toml."
fi

log "Hermes"
check "gateway running (dispatches ready tasks)" "hermes gateway status 2>&1 | grep -qiE \"running|PID [0-9]+\"" "hermes gateway start"
check "board '$BOARD' exists" "board_exists" "./factory.sh init"
for role in $ROLES; do
  p=$(profile_name "$role")
  check "profile $p exists" "profile_exists $p" "./factory.sh init"
done
check "Discord bot token set" "grep -q '^DISCORD_BOT_TOKEN=.' \"\$(hermes config env-path)\"" "./factory.sh discord"
check "Discord alerts channel set" "[ -n '$DISCORD_NOTIFY_CHANNEL' ]" "./factory.sh discord"
routes=$(routes_json)
for role in $ROLES; do
  p=$(profile_name "$role")
  check "#$role channel routed to $p" \
    "printf '%s' '$routes' | jq -e --arg p '$p' 'any(.[]; .profile == \$p and .platform == \"discord\")'" \
    "./factory.sh channels"
done

[ "$fail" = 0 ] && log "All checks passed." || { warn "Some checks failed."; exit 1; }
