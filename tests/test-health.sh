#!/usr/bin/env bash
# factory.sh health against a stub omlx server (no real model server touched).
. "$(dirname "$0")/lib.sh"
export FACTORY_STATE_DIR="$TMP/state" OMLX_API_KEY=test-key HEALTH_MODELS="coder chat"
port=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
export OMLX_URL="http://127.0.0.1:$port"
cat > "$TMP/stub.py" <<'PY'
import http.server, sys, os
status_file, log_file = sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        with open(log_file, "a") as f: f.write(f"GET {self.path} {self.headers.get('Authorization')}\n")
        body = open(status_file, "rb").read() if self.path == "/v1/models/status" else b"{}"
        self.send_response(200 if self.path == "/v1/models/status" else 404); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        with open(log_file, "a") as f: f.write(f"POST {self.path}\n")
        self.send_response(405); self.end_headers()
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
status() { # status <coder-loaded> <coder-loading> <chat-loaded>
  printf '{"loaded_count":1,"model_count":2,"final_ceiling":100,"models":[{"id":"coder","loaded":%s,"is_loading":%s,"estimated_size":40},{"id":"chat","loaded":%s,"is_loading":false,"estimated_size":30}]}' "$1" "$2" "$3" > "$TMP/status.json"
}
status true false true
python3 -I "$TMP/stub.py" "$port" "$TMP/status.json" "$TMP/requests.log" & stub=$!
trap 'kill $stub 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "$OMLX_URL/v1/models/status" && break; sleep 0.2; done

rc=0; "$ROOT/factory.sh" health >/dev/null 2>&1 || rc=$?; expect "all role models loaded -> 0" "$rc" 0
status false false true
rc=0; out=$("$ROOT/factory.sh" health 2>&1) || rc=$?; expect "a model not loaded -> 1" "$rc" 1
case "$out" in *"coder is not loaded"*) ok "names the missing model" ;; *) bad "names the missing model: $out" ;; esac
status false true true
rc=0; out=$("$ROOT/factory.sh" health 2>&1) || rc=$?; expect "a model still loading -> 1" "$rc" 1
status true false true
rc=0; out=$(HEALTH_MODELS="coder chat ghost" "$ROOT/factory.sh" health 2>&1) || rc=$?; expect "a model not on the server -> 1" "$rc" 1
rc=0; out=$(HEALTH_MODELS="coder chat" "$ROOT/factory.sh" health 2>&1) || rc=$?
printf '{"final_ceiling":50,"models":[{"id":"coder","loaded":true,"is_loading":false,"estimated_size":40},{"id":"chat","loaded":true,"is_loading":false,"estimated_size":30}]}' > "$TMP/status.json"
out=$("$ROOT/factory.sh" health 2>&1); case "$out" in *"will swap models"*) ok "warns when role models exceed the ceiling" ;; *) bad "ceiling warning: $out" ;; esac
grep -q POST "$TMP/requests.log" && bad "only GET requests" || ok "only GET requests"
grep -qv "^GET /v1/models/status " "$TMP/requests.log" && bad "only /v1/models/status: $(sort -u "$TMP/requests.log")" || ok "only /v1/models/status"
grep -q "Bearer test-key" "$TMP/requests.log" && ok "sends the API key" || bad "sends the API key"
kill $stub; wait $stub 2>/dev/null
rc=0; "$ROOT/factory.sh" health >/dev/null 2>&1 || rc=$?; expect "server down -> 1" "$rc" 1
done_testing
