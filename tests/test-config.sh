#!/usr/bin/env bash
# lib/config.py and the factory.toml loader in lib/common.sh. Uses temp config
# dirs (FACTORY_CONFIG_DIR); the real factory.conf/factory.toml are only read.
. "$(dirname "$0")/lib.sh"
CFG="$ROOT/lib/config.py"
export FACTORY_STATE_DIR="$TMP/state"
unset CHECK_TIMEOUT SMOKE_TIMEOUT OMLX_URL SCANNERS SEMGREP_CONFIG SECURITY_ROLE FACTORY_CONF_WARNED
val() { FACTORY_CONFIG_DIR="$1" bash -c ". '$ROOT/lib/common.sh'; printf '%s' \"\$$2\"" 2>/dev/null; }

expect "factory.example.toml is generated from lib/config.py" "$(python3 -I "$CFG" example | cksum)" "$(cksum < "$ROOT/factory.example.toml")"

# --- factory.toml -----------------------------------------------------------------
d="$TMP/toml"; mkdir -p "$d"
cat > "$d/factory.toml" <<'T'
[target]
repo = "/tmp/some-repo"
[board]
roles = ["planner", "backend"]
[guardrails]
failure_limit = 4
[check]
timeout = 60
scanners = ["gitleaks"]
security_role = true
[escalation]
auto = true
max_budget_usd = 2.5
[discord.channels]
integrator = "123456789012345678"
T
expect "string" "$(val "$d" TARGET_REPO)" /tmp/some-repo
expect "list -> words" "$(val "$d" ROLES)" "planner backend"
expect "int" "$(val "$d" FAILURE_LIMIT)" 4
expect "list -> csv" "$(val "$d" SCANNERS)" gitleaks
expect "bool true -> 1" "$(val "$d" SECURITY_ROLE)" 1
expect "bool -> 1 (escalation.auto)" "$(val "$d" ESCALATE_AUTO)" 1
expect "float" "$(val "$d" ESCALATE_MAX_BUDGET_USD)" 2.5
expect "discord.channels.<role>" "$(val "$d" DISCORD_CHANNEL_INTEGRATOR)" 123456789012345678
expect "missing key -> default" "$(val "$d" BOARD)" software-factory
expect "missing key -> default (int)" "$(val "$d" SMOKE_TIMEOUT)" 900
expect "env overrides an env-enabled key" "$(CHECK_TIMEOUT=5 val "$d" CHECK_TIMEOUT)" 5
expect "empty env SCANNERS turns scanners off" "$(SCANNERS= val "$d" SCANNERS)" ""
expect "env can't override other keys" "$(FAILURE_LIMIT=9 val "$d" FAILURE_LIMIT)" 4
out=$(FACTORY_CONFIG_DIR="$d" bash -c ". '$ROOT/lib/common.sh'; :" 2>&1)
case "$out" in *deprecated*) bad "no deprecation warning with factory.toml" ;; *) ok "no deprecation warning with factory.toml" ;; esac

bad_toml() { # bad_toml "name" "<toml>" "expected message part"
  local b="$TMP/bad$RANDOM"; mkdir -p "$b"; printf '%s\n' "$2" > "$b/factory.toml"
  local rc=0 o; o=$(FACTORY_CONFIG_DIR="$b" bash -c ". '$ROOT/lib/common.sh'; echo loaded" 2>&1) || rc=$?
  case "$rc:$o" in 1:*"$3"*) ok "$1" ;; *) bad "$1 (rc $rc: $o)" ;; esac
}
bad_toml "unknown key refused" $'[board]\nslgu = "x"' "unknown setting board.slgu"
bad_toml "wrong type refused" $'[check]\ntimeout = "60"' "check.timeout must be int"
bad_toml "secret refused" $'[discord]\nbot_token = "abc"' "secrets don't belong"
bad_toml "broken TOML refused" $'[check\ntimeout = 1' "config error"
bad_toml "unquoted channel id refused" $'[discord.channels]\nqa = 123' "must be a string"

# --- factory.conf fallback ------------------------------------------------------------
c="$TMP/conf"; mkdir -p "$c"
printf 'TARGET_REPO="$HOME/x"\nFAILURE_LIMIT=3\nDISCORD_CHANNEL_QA="42"\nCHECK_TIMEOUT=100\n' > "$c/factory.conf"
expect "factory.conf still read" "$(val "$c" FAILURE_LIMIT)" 3
expect "factory.conf expands \$HOME" "$(val "$c" TARGET_REPO)" "$HOME/x"
expect "factory.conf channel" "$(val "$c" DISCORD_CHANNEL_QA)" 42
expect "env still wins over factory.conf" "$(CHECK_TIMEOUT=7 val "$c" CHECK_TIMEOUT)" 7
out=$(FACTORY_CONFIG_DIR="$c" bash -c ". '$ROOT/lib/common.sh'; bash -c '. \"$ROOT/lib/common.sh\"'" 2>&1)
expect "one deprecation warning across nested scripts" "$(printf '%s\n' "$out" | grep -c deprecated)" 1

# --- migrate ------------------------------------------------------------------------
m="$TMP/migrate"; mkdir -p "$m"
if [ -f "$ROOT/factory.conf" ]; then cp "$ROOT/factory.conf" "$m/factory.conf"; else cp "$c/factory.conf" "$m/"; fi
before=$(cksum < "$m/factory.conf")
FACTORY_CONFIG_DIR="$m" "$ROOT/factory.sh" config migrate --dry-run > "$TMP/dry.toml" 2>/dev/null
[ -f "$m/factory.toml" ] && bad "migrate --dry-run writes nothing" || ok "migrate --dry-run writes nothing"
grep -q '^\[target\]' "$TMP/dry.toml" && ok "migrate --dry-run prints TOML" || bad "migrate --dry-run prints TOML"
norm() { awk '{print $1, $2}' | grep -v " ''$" | sort; }   # unset and "" are the same to bash
from_conf=$(FACTORY_CONFIG_DIR="$m" python3 -I "$CFG" show "$m" | norm)
FACTORY_CONFIG_DIR="$m" "$ROOT/factory.sh" config migrate >/dev/null 2>&1
[ -f "$m/factory.toml" ] && ok "migrate writes factory.toml" || bad "migrate writes factory.toml"
expect "factory.conf untouched" "$(cksum < "$m/factory.conf")" "$before"
from_toml=$(python3 -I "$CFG" show "$m" | norm)
expect "every value survives the migration" "$from_toml" "$from_conf"
python3 -I "$CFG" show "$m" | grep -q "factory.conf" && bad "factory.toml now wins" || ok "factory.toml now wins"
rc=0; FACTORY_CONFIG_DIR="$m" "$ROOT/factory.sh" config migrate >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] && ok "migrate won't overwrite factory.toml without --force" || bad "migrate overwrite guard"
printf 'DISCORD_BOT_TOKEN="x"\nFOO=1\n' >> "$m/factory.conf"
err=$(python3 -I "$CFG" migrate "$m" 2>&1 >/dev/null)
case "$err" in *"DISCORD_BOT_TOKEN (looks like a secret"*"FOO (not a factory setting)"*) ok "migrate skips secrets and unknown vars, and says so" ;; *) bad "migrate skip: $err" ;; esac
python3 -I "$CFG" migrate "$m" 2>/dev/null | grep -qiE '^[^#]*token' && bad "no token in the TOML" || ok "no token in the TOML"

# --- conf_set writes factory.toml, keeping comments ------------------------------------
s="$TMP/set"; mkdir -p "$s"; cp "$ROOT/factory.example.toml" "$s/factory.toml"
FACTORY_CONFIG_DIR="$s" bash -c ". '$ROOT/lib/common.sh'; conf_set DISCORD_CHANNEL_INTEGRATOR 555555555555555555; conf_set DISCORD_NOTIFY_CHANNEL 777777777777777777; conf_set FAILURE_LIMIT 5" 2>/dev/null
expect "conf_set channel" "$(val "$s" DISCORD_CHANNEL_INTEGRATOR)" 555555555555555555
expect "conf_set alerts channel" "$(val "$s" DISCORD_NOTIFY_CHANNEL)" 777777777777777777
expect "conf_set int" "$(val "$s" FAILURE_LIMIT)" 5
grep -q "^# Consecutive failures" "$s/factory.toml" && ok "comments kept" || bad "comments kept"
rc=0; python3 -I "$CFG" set "$s" DISCORD_BOT_TOKEN x 2>/dev/null || rc=$?
[ "$rc" != 0 ] && ok "conf_set refuses secrets" || bad "conf_set refuses secrets"

# --- consumers ----------------------------------------------------------------------
out=$(FACTORY_CONFIG_DIR="$d" bash -c ". '$ROOT/lib/common.sh'; OMLX_URL=http://127.0.0.1:9123/v1; for r in \$(ls '$ROOT/roles' | sed 's/.md//'); do render_role \$r; done" 2>/dev/null)
case "$out" in *"{{"*) bad "role placeholders all filled" ;; *) ok "role placeholders all filled" ;; esac
case "$out" in *"$ROOT/factory.sh smoke"*) ok "roles get this factory's path" ;; *) bad "roles get this factory's path" ;; esac
case "$out" in *"9123 is the model server"*) ok "roles get the model server port" ;; *) bad "model server port" ;; esac
hits=$(grep -rIl "/Users/" "$ROOT/roles" "$ROOT/scripts" "$ROOT/hermes-plugin" 2>/dev/null)
[ -n "$hits" ] && bad "no absolute home paths in roles/scripts/plugin: $hits" || ok "no absolute home paths in roles/scripts/plugin"

fr="$TMP/froot"; mkdir -p "$fr"; ln -s "$ROOT/lib" "$fr/lib"
printf '[board]\nslug = "other-board"\nprofile_prefix = "zz-"\n[target]\nrepo = "/tmp/r"\n[watch]\nstale_minutes = 7\n' > "$fr/factory.toml"
pd="$TMP/plugin/factory_guard"; mkdir -p "$pd"; cp "$ROOT/hermes-plugin/factory-guard/__init__.py" "$pd/"; echo "$fr" > "$pd/factory_root"
expect "guard plugin reads board and prefix" "$(cd "$TMP/plugin" && python3 -I -c 'import sys; sys.path.insert(0, "."); import factory_guard as g; print(g.BOARD, g.REVIEWER)')" "other-board zz-reviewer"
expect "factory_watch reads board, repo, thresholds" "$(FACTORY_ROOT="$fr" python3 -I -c "
src = open('$ROOT/scripts/factory_watch.py').read(); src = src[:src.index('def kanban')]
g = {}; exec(src, g); print(g['BOARD'], g['REPO'], g['STALE_SECS'], g['PREFIX'])")" "other-board /tmp/r 420 zz-"
done_testing
