#!/usr/bin/env bash
# Show the factory board: what needs you first, then everything in flight,
# then what each delivered ticket cost (scripts/cost.py, read-only).
#
#   scripts/status.sh [--cost] [--all]
#     --cost  only the cost table (doesn't touch the board)
#     --all   cost of open tickets too, not just delivered ones
. "$(dirname "$0")/../lib/common.sh"
eval "set -- $(strip_flags "$@")"
cost_only=0; cost_args=()
for a in "$@"; do
  case "$a" in
    --cost) cost_only=1 ;;
    --all) cost_args+=(--all) ;;
    *) die "usage: status.sh [--cost] [--all]" ;;
  esac
done

cost() {
  local repo="${TARGET_REPO/#\~/$HOME}"
  printf '%sCost per ticket%s\n' "$C_YEL" "$C_OFF"
  python3 -I "$FACTORY_ROOT/scripts/cost.py" --db "$(kanban_db)" --state "$STATE_DIR" \
    ${repo:+--repo "$repo"} ${cost_args[@]+"${cost_args[@]}"} || warn "cost report failed"
}
if [ "$cost_only" = 1 ]; then cost; exit 0; fi

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
echo
cost
