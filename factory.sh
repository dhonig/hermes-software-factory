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
  ticket "<title>" --done-when "<command>" [--role backend|frontend] [--details "..."]
                       fast lane: skip the Planner, one build -> security -> QA chain; the
                       check gate also requires <command> to exit 0 in the worktree
  integrate <build-id> ["what failed"]
                       hand a branch that won't merge cleanly to the Integrator
  smoke <worktree>     build the backend, start it on a free port and curl its endpoints
  check <worktree>     run ./check.sh and record a pass for HEAD (hand-offs need this)
  escalate <task-id> ["note"]
                       hand a stuck build task to headless Claude Code, then back to review
  status [--cost] [--all]
                       what's blocked, in review, running, ready; then cost per delivered
                       ticket (--cost: only that, --all: open tickets too)
  reap [<worktree>...] stop processes left running in task worktrees [--force]
  pause ["reason"]     hold every card that could start a worker, stop workers, record them
  resume [--force]     check the model server, then release exactly what pause held
  health               read-only check: omlx up and every role's model loaded

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
  ticket)   "$S/ticket.sh" "$@" ;;
  integrate) "$S/integrate.sh" "$@" ;;
  smoke)    "$S/smoke.sh" "$@" ;;
  check)    "$S/check-gate.sh" "$@" ;;
  escalate) "$S/escalate.sh" "$@" ;;
  status)   "$S/status.sh" "$@" ;;
  reap)     "$S/reap.sh" "$@" ;;
  pause)    "$S/pause.sh" "$@" ;;
  resume)   "$S/resume.sh" "$@" ;;
  health)   "$S/health.sh" "$@" ;;
  teardown) "$S/teardown.sh" "$@" ;;
  ""|-h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
