# Tiny test helpers. Source from a tests/test-*.sh script.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/factory-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
_fails=0
ok()   { printf 'ok    %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; _fails=$((_fails + 1)); }
expect() { # expect "name" <actual> <expected>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi
}
alive() { kill -0 "$1" 2>/dev/null; }
done_testing() { [ "$_fails" = 0 ] && echo "all passed" || { echo "$_fails failed"; exit 1; }; }
