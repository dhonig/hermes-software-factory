#!/usr/bin/env bash
# Smoke-test a hermes-board worktree the way a user would: build the backend,
# start it on a free port against the real Hermes home, and hit its endpoints.
# Exits non-zero on any failure and prints the server's log tail.
#
#   scripts/smoke.sh <worktree-path>
#
# The whole run is limited to SMOKE_TIMEOUT seconds (check.timeout / check.smoke_timeout in factory.toml, 0 = no limit)
# and runs in its own process group: servers, trunk and browsers it starts are
# killed when it ends, however it ends.
. "$(dirname "$0")/../lib/common.sh"

if [ -z "${_FACTORY_SMOKE_LIMITED:-}" ]; then
  rc=0
  _FACTORY_SMOKE_LIMITED=1 run_limited "$SMOKE_TIMEOUT" "$0" "$@" || rc=$?
  [ "$rc" = 124 ] && printf '%sFAIL:%s smoke test timed out after %ss (SMOKE_TIMEOUT); its processes were killed\n' \
    "$C_RED" "$C_OFF" "$SMOKE_TIMEOUT"
  exit "$rc"
fi

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
  # A stylesheet that serves 200 can still be empty: it must keep the core classes.
  css=$(printf '%s\n' "$assets" | grep '\.css$' | head -1)
  if [ -n "$css" ]; then
    case "$css" in /*) ;; *) css="/$css" ;; esac
    curl -s -o "$body" "$base$css"
    for cls in .app-header .board-card .column .task-card .status-done .status-blocked; do
      grep -qF -- "$cls" "$body" || fail "stylesheet $css is missing $cls ($(wc -c < "$body" | tr -d ' ') bytes)"
    done
    pass "stylesheet has the core classes"
  fi
  code=$(curl -s -o "$body" -w '%{http_code}' "$base/boards/software-factory")
  [ "$code" = 200 ] && grep -qi '<html' "$body" || fail "client route /boards/software-factory returned $code, expected the index.html fallback"
  pass "GET /boards/software-factory 200 (SPA fallback)"

  # Render the app in a headless browser and check what a user would see: the
  # boards screen must list the boards /api/boards returns, and no page may show
  # an error. Catches API/client mismatches that compile and pass every test.
  # scripts/render.js (playwright-core) waits for the app to load, not for network
  # idle, so pages holding an EventSource open still render.
  chrome="${SMOKE_CHROME:-}"
  if [ -z "$chrome" ]; then
    chrome=$(ls -d "$HOME"/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell 2>/dev/null | sort -V | tail -1)
  fi
  [ -z "$chrome" ] && [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ] \
    && chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  pw_path="${SMOKE_NODE_PATH:-$HOME/.hermes/hermes-agent/node_modules}"
  if [ -n "$chrome" ] && [ -x "$chrome" ] && command -v node >/dev/null && [ -d "$pw_path/playwright-core" ]; then
    render() { CHROME="$chrome" NODE_PATH="$pw_path" perl -e 'alarm shift; exec @ARGV' 60 \
      node "$FACTORY_ROOT/scripts/render.js" "$base$1" ${2:+"$2"} 2>&1 || true; }
    shots="$STATE_DIR/screenshots"; mkdir -p "$shots"
    name=$(basename "$wt")
    names=$(curl -s "$base/api/boards" | jq -r '(if type=="array" then . else .boards end)[].name')
    text=$(render / "$shots/$name-root.png")
    [ -n "$text" ] || fail "rendering / produced no text"
    case "$text" in *Error*) fail "boards screen (/) renders an error: $(printf '%s' "$text" | grep -o 'Error[^.]*' | head -1)" ;; esac
    if case "$text" in *"Boards TODO"*) true ;; *) false ;; esac; then
      warn "boards screen (/) is still a placeholder: $(printf '%s' "$text" | head -c 120)"
    else
      printf '%s\n' "$names" | while IFS= read -r n; do
        [ -z "$n" ] && continue
        case "$text" in *"$n"*) ;; *) echo "missing board '$n' on /"; exit 1 ;; esac
      done || fail "boards screen (/) does not list every board from /api/boards. Rendered text: $(printf '%s' "$text" | head -c 300)"
      pass "rendered / lists: $(printf '%s' "$names" | tr '\n' ',' | sed 's/,$//')"
    fi
    slug=$(curl -s "$base/api/boards" | jq -r '(if type=="array" then . else .boards end)[0].slug')
    text=$(render "/boards/$slug" "$shots/$name-board.png")
    [ -n "$text" ] || fail "rendering /boards/$slug produced no text"
    case "$text" in *Error*) fail "board screen (/boards/$slug) renders an error: $(printf '%s' "$text" | grep -o 'Error[^.]*' | head -1)" ;; esac
    pass "rendered /boards/$slug without errors: $(printf '%s' "$text" | head -c 100)"
    # Task detail. Task text can quote errors, so only render.js's own "Error (" lines
    # count here, plus the page's error state, and the task's title must be on the page.
    task=$(curl -s "$base/api/boards/$slug/tasks" | jq -c '.[0] // empty')
    if [ -n "$task" ]; then
      tid=$(printf '%s' "$task" | jq -r .id); title=$(printf '%s' "$task" | jq -r .title)
      text=$(render "/boards/$slug/tasks/$tid" "$shots/$name-task.png")
      case "$text" in
        *"Error ("*|*"Error loading"*) fail "task page (/boards/$slug/tasks/$tid) renders an error: $(printf '%s' "$text" | head -c 200)" ;;
      esac
      case "$text" in
        *"$title"*) pass "rendered /boards/$slug/tasks/$tid: $title" ;;
        *) fail "task page (/boards/$slug/tasks/$tid) does not show the task title '$title'. Rendered text: $(printf '%s' "$text" | head -c 300)" ;;
      esac
    fi
    pass "screenshots in $shots/$name-root.png, $name-board.png and $name-task.png"

    # Live updates, against a scratch copy of the fixture board (never a real board).
    if [ -d "$wt/fixtures/kanban/boards/fixtures" ] && command -v sqlite3 >/dev/null; then
      live_home="$STATE_DIR/smoke.$$.home"; rm -rf "$live_home"; cp -R "$wt/fixtures" "$live_home"
      live_port=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
      (cd "$wt" && HERMES_HOME="$live_home" BIND="127.0.0.1:$live_port" exec "$bin") >> "$server_log" 2>&1 &
      live_pid=$!
      for _ in $(seq 1 20); do curl -s -o /dev/null "http://127.0.0.1:$live_port/api/health" && break; sleep 0.5; done
      live_out=$(CHROME="$chrome" NODE_PATH="$pw_path" perl -e 'alarm shift; exec @ARGV' 60 \
        node "$FACTORY_ROOT/scripts/livetest.js" "http://127.0.0.1:$live_port" fixtures \
        "$live_home/kanban/boards/fixtures/kanban.db" 2>&1 || true)
      # Drag and drop uses the real hermes CLI, so it only ever runs on this scratch copy:
      # the server passes HERMES_KANBAN_HOME=$live_home to the CLI.
      drag_out=$(CHROME="$chrome" NODE_PATH="$pw_path" perl -e 'alarm shift; exec @ARGV' 90 \
        node "$FACTORY_ROOT/scripts/dragtest.js" "http://127.0.0.1:$live_port" fixtures t_ready_006 2>&1 || true)
      kill "$live_pid" 2>/dev/null || true; wait "$live_pid" 2>/dev/null || true; rm -rf "$live_home"
      case "$drag_out" in
        ok:*) pass "drag and drop: ${drag_out#ok: }" ;;
        *) if [ -n "${SMOKE_REQUIRE_DRAG:-}" ]; then fail "drag and drop: $drag_out"; else warn "drag and drop: $drag_out"; fi ;;
      esac
      case "$live_out" in *"archived hidden"*) pass "archived hidden with the toggle off" ;; esac
      live_out=$(printf '%s\n' "$live_out" | grep -v '^archived hidden$')
      case "$live_out" in
        ok:*) pass "live updates: ${live_out#ok: }" ;;
        *) if [ -n "${SMOKE_REQUIRE_LIVE:-}" ]; then fail "live updates: $live_out"; else warn "live updates: $live_out"; fi ;;
      esac
    fi
  else
    warn "no headless Chrome, node or playwright-core found (set SMOKE_CHROME / SMOKE_NODE_PATH); skipped the rendered-page checks"
  fi
fi

rm -f "$server_log"
log "Smoke test passed for $wt"
