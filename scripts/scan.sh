#!/usr/bin/env bash
# Security scanners for a task branch, run by the check gate after ./check.sh.
# Replaces the sf-security model role by default (SECURITY_ROLE=0).
#
#   scripts/scan.sh <worktree-path>
#
#   gitleaks  secrets in the commits on the branch (main..HEAD)
#   semgrep   findings in the files the branch changed (SEMGREP_CONFIG, default p/default)
#
# check.scanners in factory.toml picks them: ["gitleaks", "semgrep"] (default), or [] for none.
# A scanner that isn't installed is skipped with a warning, so the gate still
# passes; ./factory.sh doctor lists what's missing. Exits 1 on any finding.
. "$(dirname "$0")/../lib/common.sh"

[ $# -ge 1 ] || die "usage: scan.sh <worktree-path>"
wt="$(cd "$1" && pwd)" || die "No such worktree: $1"
base="${SCAN_BASE:-main}"

if ! git -C "$wt" rev-parse -q --verify "$base" >/dev/null; then
  warn "scan: no '$base' branch in $wt; skipping scanners"
  exit 0
fi
range="$base..HEAD"
if [ "$(git -C "$wt" rev-list --count "$range")" = 0 ]; then
  log "scan: no commits on the branch beyond $base; nothing to scan"
  exit 0
fi

found=0
for scanner in $(printf '%s' "$SCANNERS" | tr ',' ' '); do
  case "$scanner" in
    gitleaks)
      if ! command -v gitleaks >/dev/null; then
        warn "scan: gitleaks is not installed (brew install gitleaks); skipped the secrets scan"
        continue
      fi
      log "scan: gitleaks on $range"
      rc=0
      (cd "$wt" && run_limited "$CHECK_TIMEOUT" gitleaks git . --log-opts="$range" \
        --no-banner --redact --exit-code 1) || rc=$?
      if [ "$rc" != 0 ]; then
        printf '%sFAIL:%s gitleaks found secrets in %s (exit %s); findings above are redacted\n' "$C_RED" "$C_OFF" "$range" "$rc"
        found=1
      fi ;;
    semgrep)
      if ! command -v semgrep >/dev/null; then
        warn "scan: semgrep is not installed (brew install semgrep); skipped the code scan"
        continue
      fi
      files=()
      while IFS= read -r f; do
        [ -n "$f" ] && [ -f "$wt/$f" ] && files+=("$f")
      done <<EOF
$(git -C "$wt" diff --name-only --diff-filter=ACMR "$base...HEAD")
EOF
      [ ${#files[@]} -gt 0 ] || { log "scan: semgrep has no changed files to scan"; continue; }
      log "scan: semgrep (${SEMGREP_CONFIG}) on ${#files[@]} changed file(s)"
      rc=0
      (cd "$wt" && run_limited "$CHECK_TIMEOUT" semgrep scan --config "$SEMGREP_CONFIG" --metrics off \
        --error --quiet --disable-version-check "${files[@]}") || rc=$?
      if [ "$rc" != 0 ]; then
        printf '%sFAIL:%s semgrep reported findings or failed (exit %s)\n' "$C_RED" "$C_OFF" "$rc"
        found=1
      fi ;;
    "") ;;
    *) warn "scan: unknown scanner '$scanner' in SCANNERS" ;;
  esac
done
exit "$found"
