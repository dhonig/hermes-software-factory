#!/usr/bin/env bash
# Hermes software factory: one entry point for every step.
# Every command accepts --dry-run to print what it would do.
set -euo pipefail
S="$(cd "$(dirname "$0")" && pwd)/scripts"

usage() {
  cat <<'EOF'
usage: ./factory.sh <command> [args] [--dry-run]

Setup
  init                 board + role profiles + guardrails + .ecc/memory + guard plugin (safe to rerun)
  discord              connect the gateway to Discord (interactive; you paste the token)
  channels             give each role its own Discord channel (asks for 6 channel IDs)
  doctor               check tools, config, gateway, board, profiles

Work
  feature "<goal>"     ask the Planner for a plan [--details "..."]
  approve <task-id>    review the plan and create build -> security -> QA tasks [--yes]
  integrate <build-id> ["what failed"]
                       hand a branch that won't merge cleanly to the Planner
  status               what's blocked, in review, running, ready

Cleanup
  teardown             archive the board, delete factory profiles, restore settings
EOF
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  init)
    "$S/init-board.sh" "$@"
    "$S/create-profiles.sh" "$@"
    "$S/configure-guardrails.sh" "$@"
    "$S/memory-init.sh" "$@"
    "$S/install-guard.sh" "$@"
    echo; echo "Next: ./factory.sh discord, then ./factory.sh doctor" ;;
  discord)  "$S/discord-setup.sh" "$@" ;;
  channels) "$S/discord-roles.sh" "$@" ;;
  doctor)   "$S/doctor.sh" "$@" ;;
  feature)  "$S/new-feature.sh" "$@" ;;
  approve)  "$S/approve-plan.sh" "$@" ;;
  integrate) "$S/integrate.sh" "$@" ;;
  status)   "$S/status.sh" "$@" ;;
  teardown) "$S/teardown.sh" "$@" ;;
  ""|-h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
