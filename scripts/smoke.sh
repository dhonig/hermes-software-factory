#!/usr/bin/env bash
# Smoke-test a hermes-board worktree the way a user would: build the backend,
# start it on a free port against the real Hermes home, and hit its endpoints.
# Exits non-zero on any failure and prints the server's log tail.
#
#   scripts/smoke.sh <worktree-path>
. "$(dirname "$0")/../lib/common.sh"

[ $# -ge 1 ] || die "usage: smoke.sh <worktree-path>"
wt="$(cd "$1" && pwd)" || die "No such worktree: $1"
[ -f "$wt/Cargo.toml" ] || die "$wt has no Cargo.toml"

home="${SMOKE_HERMES_HOME:-$HOME/.hermes}"
port=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
base="http://127.0.0.1:$port"
server_log="$STATE_DIR/smoke.$$.log"
body="$STATE_DIR/smoke.$$.body"
pid=""

cleanup() {
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  rm -f "$body"
}
trap cleanup EXIT

fail() {
  printf '%sFAIL:%s %s\n' "$C_RED" "$C_OFF" "$*"
  echo "--- server log (last 30 lines) ---"
  tail -30 "$server_log" 2>/dev/null || true
  rm -f "$server_log"
  exit 1
}
pass() { printf '%sok:%s %s\n' "$C_GRN" "$C_OFF" "$*"; }

log "Building hermes-board-backend in $wt"
(cd "$wt" && cargo build -q -p hermes-board-backend) || fail "cargo build failed"
bin="$(cd "$wt" && cargo metadata -q --format-version 1 --no-deps | jq -r .target_directory)/debug/hermes-board-backend"
[ -x "$bin" ] || fail "binary not found at $bin"

frontend_built=0
if command -v trunk >/dev/null 2>&1; then
  log "Building the frontend with trunk (crates/frontend -> crates/frontend/public)"
  (cd "$wt/crates/frontend" && trunk build >"$STATE_DIR/smoke.$$.trunk.log" 2>&1) || {
    tail -30 "$STATE_DIR/smoke.$$.trunk.log"; rm -f "$STATE_DIR/smoke.$$.trunk.log"; fail "trunk build failed"; }
  rm -f "$STATE_DIR/smoke.$$.trunk.log"
  [ -f "$wt/crates/frontend/public/index.html" ] || fail "trunk build produced no crates/frontend/public/index.html"
  frontend_built=1
else
  warn "trunk is not installed; skipping the frontend build and GET / checks"
fi

log "Starting server on $base (HERMES_HOME=$home)"
# Run from the worktree root: static files are served from crates/frontend/public.
(cd "$wt" && HERMES_HOME="$home" BIND="127.0.0.1:$port" exec "$bin") > "$server_log" 2>&1 &
pid=$!

up=0
for _ in $(seq 1 30); do
  kill -0 "$pid" 2>/dev/null || fail "server exited during startup"
  if curl -s -o /dev/null "$base/api/health"; then up=1; break; fi
  sleep 1
done
[ "$up" = 1 ] || fail "server did not answer on $base within 30s"

code=$(curl -s -o "$body" -w '%{http_code}' "$base/api/health")
[ "$code" = 200 ] || fail "GET /api/health returned $code: $(head -c 300 "$body")"
pass "GET /api/health 200 $(head -c 200 "$body")"

code=$(curl -s -o "$body" -w '%{http_code}' "$base/api/boards")
[ "$code" = 200 ] || fail "GET /api/boards returned $code: $(head -c 300 "$body")"
n=$(jq 'if type == "array" then length else (.boards // []) | length end' "$body" 2>/dev/null) \
  || fail "GET /api/boards did not return JSON: $(head -c 300 "$body")"
[ "$n" -ge 1 ] || fail "GET /api/boards returned 0 boards (expected the boards under $home/kanban/boards)"
pass "GET /api/boards 200, $n board(s): $(jq -c '[.. | .slug? // empty]' "$body")"

if [ "$frontend_built" = 1 ]; then
  code=$(curl -s -o "$body" -w '%{http_code}' "$base/")
  [ "$code" = 200 ] && grep -qi '<html' "$body" || fail "GET / returned $code without index.html"
  pass "GET / 200 index.html"
  # Every .js/.wasm/.css asset index.html references must be served.
  assets=$(grep -oE '(href|src)="/?[^"]+\.(js|wasm|css)"' "$body" | sed -E 's/^(href|src)="//; s/"$//' | sort -u)
  [ -n "$assets" ] || fail "index.html references no .js/.wasm assets"
  for a in $assets; do
    case "$a" in /*) ;; *) a="/$a" ;; esac
    code=$(curl -s -o /dev/null -w '%{http_code}' "$base$a")
    [ "$code" = 200 ] || fail "GET $a returned $code"
    pass "GET $a 200"
  done
  code=$(curl -s -o "$body" -w '%{http_code}' "$base/boards/software-factory")
  [ "$code" = 200 ] && grep -qi '<html' "$body" || fail "client route /boards/software-factory returned $code, expected the index.html fallback"
  pass "GET /boards/software-factory 200 (SPA fallback)"
fi

rm -f "$server_log"
log "Smoke test passed for $wt"
