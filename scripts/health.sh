#!/usr/bin/env bash
# Is the model server ready for the factory? Read-only: it only GETs omlx's
# /v1/models/status and never calls a load or unload endpoint.
#
#   scripts/health.sh [--quiet]
#
# Checks that omlx answers, and that every role's model (each sf-* profile's
# model.default) is loaded and not loading. Warns when the role models together
# don't fit omlx's memory ceiling, since omlx would then swap models mid-run and
# crash workers. Exits 1 when something is not ready.
#
# Settings (factory.toml [models], or environment):
#   OMLX_URL      server root (default: the default profile's model.base_url without /v1)
#   OMLX_API_KEY  bearer token (default: providers.omlx.api_key in ~/.hermes/config.yaml)
#   HEALTH_MODELS space-separated model ids to require instead of reading the profiles
. "$(dirname "$0")/../lib/common.sh"
eval "set -- $(strip_flags "$@")"

quiet=0
[ "${1:-}" = --quiet ] && quiet=1
say()  { [ "$quiet" = 1 ] || printf '  %s%-4s%s  %s\n' "$1" "$2" "$C_OFF" "$3"; }
fails=0
okay() { say "$C_GRN" ok "$1"; }
bad()  { say "$C_RED" FAIL "$1"; [ "$quiet" = 1 ] && printf 'health: %s\n' "$1" >&2; fails=$((fails + 1)); }
note() { say "$C_YEL" warn "$1"; }

url="${OMLX_URL:-}"
if [ -z "$url" ]; then
  url=$(hermes config get model.base_url 2>/dev/null || true)
  url="${url%/}"; url="${url%/v1}"
fi
[ -n "$url" ] || die "No model server URL: set models.omlx_url in factory.toml."

key="${OMLX_API_KEY:-}"
if [ -z "$key" ]; then
  key=$(python3 -I -c '
import os, sys
try:
    import yaml
    c = yaml.safe_load(open(os.path.expanduser("~/.hermes/config.yaml"))) or {}
except Exception:
    sys.exit(0)
print(((c.get("providers") or {}).get("omlx") or {}).get("api_key") or (c.get("model") or {}).get("api_key") or "")
' 2>/dev/null || true)
fi

# Which model each role runs ("model<TAB>profile"), read straight from each
# profile's config.yaml (the hermes CLI takes about a second per call).
role_models() {
  local m profiles=""
  if [ -n "${HEALTH_MODELS:-}" ]; then
    for m in $HEALTH_MODELS; do printf '%s\t%s\n' "$m" "(HEALTH_MODELS)"; done
    return
  fi
  for m in $(active_roles); do profiles="$profiles $(profile_name "$m")"; done
  # shellcheck disable=SC2086
  python3 -I - $profiles <<'PY'
import os, sys
import yaml
home = os.path.expanduser("~/.hermes")
def model(path):
    try:
        c = yaml.safe_load(open(path)) or {}
    except OSError:
        return ""
    m = c.get("model")
    return (m.get("default") if isinstance(m, dict) else m) or ""
default = model(os.path.join(home, "config.yaml"))
for p in sys.argv[1:]:
    print(f"{model(os.path.join(home, 'profiles', p, 'config.yaml')) or default}\t{p}")
PY
}

[ "$quiet" = 1 ] || log "Model server $url (read-only probe)"
# The key goes to curl on stdin, never on a command line.
status=$(printf 'Authorization: Bearer %s\n' "$key" \
  | curl -s -m 10 -H @- -w '\n%{http_code}' "$url/v1/models/status" 2>/dev/null || true)
code=$(printf '%s' "$status" | tail -1)
body=$(printf '%s' "$status" | sed '$d')
if [ "$code" != 200 ] || ! printf '%s' "$body" | jq -e '.models | type == "array"' >/dev/null 2>&1; then
  bad "omlx is not answering at $url/v1/models/status (HTTP ${code:-none})"
  exit 1
fi
okay "omlx up: $(printf '%s' "$body" | jq -r '"\(.loaded_count // "?") of \(.model_count // "?") models loaded"')"

need=$(role_models | awk -F'\t' '$1 != "" { u[$1] = u[$1] (u[$1] ? ", " : "") $2 } END { for (m in u) print m "\t" u[m] }' | sort)
total=0
while IFS="$(printf '\t')" read -r model users; do
  [ -z "$model" ] && continue
  row=$(printf '%s' "$body" | jq -c --arg m "$model" '[.models[] | select(.id == $m)][0] // empty')
  if [ -z "$row" ]; then
    bad "$model is not on the server (used by $users)"
    continue
  fi
  size=$(printf '%s' "$row" | jq -r '.estimated_size // 0 | floor')
  total=$((total + size))
  if [ "$(printf '%s' "$row" | jq -r '.is_loading')" = true ]; then
    bad "$model is still loading (used by $users)"
  elif [ "$(printf '%s' "$row" | jq -r '.loaded')" != true ]; then
    bad "$model is not loaded (used by $users). Load it in oMLX, then rerun."
  else
    okay "$model loaded (used by $users)"
  fi
done <<EOF
$need
EOF

ceiling=$(printf '%s' "$body" | jq -r '.final_ceiling // 0 | floor')
if [ "$ceiling" -gt 0 ] && [ "$total" -gt "$ceiling" ]; then
  note "role models need $((total / 1000000000)) GB but omlx's ceiling is $((ceiling / 1000000000)) GB: it will swap models mid-run"
fi

if [ "$fails" -gt 0 ]; then
  [ "$quiet" = 1 ] || warn "Model server not ready ($fails problem(s))."
  exit 1
fi
[ "$quiet" = 1 ] || log "Model server ready."
