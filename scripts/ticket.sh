#!/usr/bin/env bash
# Fast lane for small tickets: skip the Planner and plan approval, and create one
# build -> QA chain directly (the same chain approve creates; with
# SECURITY_ROLE=1 a security check sits between them).
#
#   scripts/ticket.sh "<title>" --done-when "<command>" [--role backend|frontend] [--details "..."]
#
# --done-when is a shell command run in the task worktree that must exit 0 for
# the ticket to be done, e.g. --done-when "cargo test -p backend health". The
# check gate (factory.sh check) runs it after ./check.sh and only records a pass
# when both succeed, so no hand-off happens until it holds. It is stored in
# .factory/done-when/<worktree-name>, outside the repo, where the builder can't
# change it. --role defaults to backend.
. "$(dirname "$0")/../lib/common.sh"
eval "set -- $(strip_flags "$@")"
require_target_repo

usage="usage: ticket.sh \"<title>\" --done-when \"<command>\" [--role backend|frontend] [--details \"...\"]"
[ $# -ge 1 ] || die "$usage"
title="$1"; shift
role=backend; details=""; done_when=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || die "$1 needs a value. $usage"
  case "$1" in
    --done-when) done_when="$2" ;;
    --role) role="$2" ;;
    --details) details="$2" ;;
    *) die "unknown option: $1. $usage" ;;
  esac
  shift 2
done
[ -n "$title" ] || die "$usage"
[ -n "$done_when" ] || die "--done-when is required: the command that proves the ticket is done. $usage"
case "$role" in backend|frontend) ;; *) die "--role must be backend or frontend" ;; esac

slug=$(slugify "$title")
[ -n "$slug" ] || die "The title needs some letters or digits."
branch="factory/ticket/$slug"
wt="$WORKTREE_ROOT/ticket-$slug"
key="ticket:$slug"

scope="$title${details:+

$details}

Done when this command exits 0 in the worktree (the check gate runs it after ./check.sh):
    $done_when"

require_healthy

done_file="$STATE_DIR/done-when/$(basename "$wt")"
if [ -f "$done_file" ] && [ "$(cat "$done_file")" != "$done_when" ]; then
  die "A ticket for this title already has a different done-when ($done_file): $(cat "$done_file")"
fi
if [ "$DRY_RUN" = 1 ]; then
  printf '%s[dry-run]%s write %s: %s\n' "$C_DIM" "$C_OFF" "$done_file" "$done_when"
else
  mkdir -p "$STATE_DIR/done-when"
  printf '%s\n' "$done_when" > "$done_file"
fi

create_chain "$role" "$title" "$scope" "$branch" "$wt" "$key" "" "Ticket (fast lane, no plan)." \
  "Acceptance criteria: $scope"
log "[$role] $title: $CHAIN_DESC"
log "Done when: $done_when (enforced by factory.sh check in $wt)"
