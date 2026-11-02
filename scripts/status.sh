#!/usr/bin/env bash
# Show the factory board: what needs you first, then everything in flight.
. "$(dirname "$0")/../lib/common.sh"

board_exists || die "Board '$BOARD' doesn't exist yet. Run ./factory.sh init"
route_reviews

section() {
  local out
  out=$(kanban list --status "$1" --json 2>/dev/null \
    | jq -r '(if type=="array" then . else .tasks end)[]
             | "  \(.id)  \(.assignee // "-" | .[0:14])  \(.title)"' 2>/dev/null || true)
  [ -n "$out" ] && { printf '%s%s%s\n%s\n' "$C_YEL" "$2" "$C_OFF" "$out"; }
  return 0
}

section blocked "Blocked (needs you)"
section review  "Waiting for review"
section running "Running"
section ready   "Ready"
section todo    "Waiting on dependencies"
echo
kanban stats 2>/dev/null || true
