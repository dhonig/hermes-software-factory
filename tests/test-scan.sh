#!/usr/bin/env bash
# Security scanners in the check gate (stub gitleaks/semgrep), and the optional
# security role in the task chain (approve/ticket dry-runs).
. "$(dirname "$0")/lib.sh"
export FACTORY_STATE_DIR="$TMP/state" FACTORY_SKIP_HEALTH=1
stubs="$TMP/bin"; mkdir -p "$stubs"
for s in gitleaks semgrep; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\nexit "${%s_RC:-0}"\n' "$s" "$TMP" "$(echo $s | tr a-z A-Z)" > "$stubs/$s"
  chmod +x "$stubs/$s"
done
nostubs="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v "$stubs" | while read -r d; do [ -x "$d/gitleaks" ] || [ -x "$d/semgrep" ] || printf '%s:' "$d"; done)"

wt="$TMP/wt"; mkdir -p "$wt"
printf '#!/bin/sh\nexit 0\n' > "$wt/check.sh"; chmod +x "$wt/check.sh"
git -C "$wt" init -q -b main && git -C "$wt" add -A && git -C "$wt" -c user.name=t -c user.email=t@t commit -qm init
git -C "$wt" checkout -q -b factory/x
echo 'print(1)' > "$wt/app.py"; git -C "$wt" add app.py && git -C "$wt" -c user.name=t -c user.email=t@t commit -qm change

rc=0; PATH="$stubs:$PATH" "$ROOT/factory.sh" check "$wt" >/dev/null 2>&1 || rc=$?
expect "clean scan: gate passes" "$rc" 0
grep -q "^gitleaks git . --log-opts=main..HEAD .*--redact --exit-code 1" "$TMP/calls.log" && ok "gitleaks scans main..HEAD, redacted" || bad "gitleaks args: $(cat "$TMP/calls.log")"
grep -q "^semgrep scan --config p/default --metrics off --error .* app.py" "$TMP/calls.log" && ok "semgrep scans only changed files, metrics off" || bad "semgrep args: $(cat "$TMP/calls.log")"
rm -rf "$FACTORY_STATE_DIR/check-pass"

rc=0; out=$(PATH="$stubs:$PATH" GITLEAKS_RC=1 "$ROOT/factory.sh" check "$wt" 2>&1) || rc=$?
[ "$rc" != 0 ] && ok "gitleaks finding fails the gate" || bad "gitleaks finding fails the gate"
case "$out" in *"gitleaks found secrets"*) ok "says gitleaks found secrets" ;; *) bad "message: $out" ;; esac
ls "$FACTORY_STATE_DIR/check-pass" 2>/dev/null | grep -q . && bad "no pass on a finding" || ok "no pass on a finding"

rc=0; PATH="$stubs:$PATH" SEMGREP_RC=1 "$ROOT/factory.sh" check "$wt" >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] && ok "semgrep finding fails the gate" || bad "semgrep finding fails the gate"

rc=0; out=$(PATH="$nostubs" "$ROOT/factory.sh" check "$wt" 2>&1) || rc=$?
expect "scanners missing: gate still passes" "$rc" 0
case "$out" in *"gitleaks is not installed"*"semgrep is not installed"*) ok "warns about each missing scanner" ;; *) bad "warnings: $out" ;; esac
rm -rf "$FACTORY_STATE_DIR/check-pass"

: > "$TMP/calls.log"
rc=0; PATH="$stubs:$PATH" SCANNERS="" GITLEAKS_RC=1 "$ROOT/factory.sh" check "$wt" >/dev/null 2>&1 || rc=$?
expect "SCANNERS='' turns scanning off" "$rc$(wc -l < "$TMP/calls.log" | tr -d ' ')" 00
rm -rf "$FACTORY_STATE_DIR/check-pass"

git -C "$wt" checkout -q main
: > "$TMP/calls.log"; rc=0; PATH="$stubs:$PATH" GITLEAKS_RC=1 "$ROOT/factory.sh" check "$wt" >/dev/null 2>&1 || rc=$?
expect "nothing beyond main: scanners not run" "$rc$(wc -l < "$TMP/calls.log" | tr -d ' ')" 00

# --- chain shape ----------------------------------------------------------------
repo="$TMP/target"; mkdir -p "$repo"; git -C "$repo" init -q
export FACTORY_TARGET_REPO="$repo"
out=$("$ROOT/factory.sh" ticket "Thing" --done-when true --dry-run 2>&1)
case "$out" in *"sf-security"*) bad "default chain has no security task" ;; *) ok "default chain has no security task" ;; esac
case "$out" in *"qa t_dryrun"*) ok "QA hangs off the build" ;; *) bad "QA: $out" ;; esac
build=$(printf '%s\n' "$out" | sed -nE 's/.*build (t_dryrun[0-9]+) -> qa.*/\1/p')
printf '%s\n' "$out" | grep -q -- "--assignee sf-qa .*--parent $build " && ok "QA's parent is the build" || bad "QA's parent is the build"
out=$(SECURITY_ROLE=1 "$ROOT/factory.sh" ticket "Thing" --done-when true --dry-run 2>&1)
case "$out" in *"--assignee sf-security"*"-> security t_dryrun"*"-> qa"*) ok "SECURITY_ROLE=1 restores the security task" ;; *) bad "SECURITY_ROLE=1: $out" ;; esac
done_testing
