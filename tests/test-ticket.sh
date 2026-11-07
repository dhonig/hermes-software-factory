#!/usr/bin/env bash
# Fast lane: factory.sh ticket (dry-run), the check gate's done-when, and the
# guard plugin's per-worktree pass. No board or model needed.
. "$(dirname "$0")/lib.sh"
export FACTORY_STATE_DIR="$TMP/state" FACTORY_SKIP_HEALTH=1
mkdir -p "$FACTORY_STATE_DIR/done-when"

# --- check gate ---------------------------------------------------------------
wt="$TMP/repo/.worktrees/ticket-add-x"; mkdir -p "$wt"
printf '#!/bin/sh\nexit 0\n' > "$wt/check.sh"; chmod +x "$wt/check.sh"
git -C "$wt" init -q && git -C "$wt" add -A && git -C "$wt" -c user.name=t -c user.email=t@t commit -qm init
sha=$(git -C "$wt" rev-parse HEAD)
echo 'test -f done.txt' > "$FACTORY_STATE_DIR/done-when/ticket-add-x"
rc=0; out=$("$ROOT/factory.sh" check "$wt" 2>&1) || rc=$?
[ "$rc" != 0 ] && ok "gate fails while done-when fails" || bad "gate fails while done-when fails"
case "$out" in *"done-when exited"*) ok "says done-when failed" ;; *) bad "says done-when failed: $out" ;; esac
ls "$FACTORY_STATE_DIR/check-pass" 2>/dev/null | grep -q . && bad "no pass recorded" || ok "no pass recorded"
touch "$wt/done.txt"; git -C "$wt" add done.txt && git -C "$wt" -c user.name=t -c user.email=t@t commit -qm done
sha=$(git -C "$wt" rev-parse HEAD)
rc=0; "$ROOT/factory.sh" check "$wt" >/dev/null 2>&1 || rc=$?
expect "gate passes once done-when holds" "$rc" 0
[ -f "$FACTORY_STATE_DIR/check-pass/$sha@ticket-add-x" ] && ok "pass keyed by commit and worktree" || bad "pass keyed by commit and worktree"
[ -f "$FACTORY_STATE_DIR/check-pass/$sha" ] && bad "no plain pass for a ticket" || ok "no plain pass for a ticket"

# --- guard plugin -------------------------------------------------------------
plug="$TMP/plugin"; mkdir -p "$plug"; cp "$ROOT/hermes-plugin/factory-guard/__init__.py" "$plug/factory_guard.py"
froot="$TMP/froot"; mkdir -p "$froot/.factory/check-pass" "$froot/.factory/done-when"; echo "$froot" > "$plug/factory_root"
guard() { HERMES_KANBAN_WORKSPACE="$1" python3 -I -c "
import sys; sys.path.insert(0, '$plug'); import factory_guard as g
print('allow' if g._check_gate() is None else 'block')"; }
touch "$froot/.factory/check-pass/$sha"
expect "plain ticket worktree with a plain pass: allowed" "$(guard "$wt")" allow
echo x > "$froot/.factory/done-when/ticket-add-x"
expect "ticket worktree with only a plain pass: blocked" "$(guard "$wt")" block
touch "$froot/.factory/check-pass/$sha@ticket-add-x"
expect "ticket worktree with a ticket pass: allowed" "$(guard "$wt")" allow

# --- ticket.sh ------------------------------------------------------------------
repo="$TMP/target"; mkdir -p "$repo"; git -C "$repo" init -q
export FACTORY_TARGET_REPO="$repo"
out=$("$ROOT/factory.sh" ticket "Add the X endpoint" --done-when "cargo test x" --dry-run 2>&1); rc=$?
expect "dry-run exits 0" "$rc" 0
case "$out" in *"create Add\\ the\\ X\\ endpoint --assignee sf-backend --workspace worktree:"*"ticket-add-the-x-endpoint --branch factory/ticket/add-the-x-endpoint"*) ok "build task in its own worktree and branch" ;; *) bad "build task: $out" ;; esac
case "$out" in *"--assignee sf-security --workspace dir:"*"--assignee sf-qa --workspace dir:"*) ok "security and QA follow" ;; *) bad "chain: $out" ;; esac
case "$out" in *"Planner"*|*"sf-planner"*) bad "skips the Planner" ;; *) ok "skips the Planner" ;; esac
case "$out" in *"write "*"done-when/ticket-add-the-x-endpoint: cargo test x"*) ok "shows the done-when it stores" ;; *) bad "done-when: $out" ;; esac
[ -f "$FACTORY_STATE_DIR/done-when/ticket-add-the-x-endpoint" ] && bad "dry-run stores nothing" || ok "dry-run stores nothing"
rc=0; "$ROOT/factory.sh" ticket "No proof" --dry-run >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] && ok "--done-when is required" || bad "--done-when is required"
rc=0; "$ROOT/factory.sh" ticket "Bad role" --done-when true --role qa --dry-run >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] && ok "--role must be a builder" || bad "--role must be a builder"
out=$("$ROOT/factory.sh" ticket "Frontend thing" --done-when true --role frontend --dry-run 2>&1)
case "$out" in *"--assignee sf-frontend"*) ok "--role frontend" ;; *) bad "--role frontend" ;; esac
done_testing
