#!/usr/bin/env bash
# Seed ECC-style shared memory (.ecc/memory/) in the target repo.
# Existing files are never overwritten.
. "$(dirname "$0")/../lib/common.sh"
require_target_repo

dest="$TARGET_REPO/.ecc/memory"
run mkdir -p "$dest"
for f in "$FACTORY_ROOT"/templates/memory/*.md; do
  name=$(basename "$f")
  if [ -e "$dest/$name" ]; then
    log "Keeping existing .ecc/memory/$name"
  else
    log "Adding .ecc/memory/$name"
    run cp "$f" "$dest/$name"
  fi
done

# Task worktrees live in <repo>/.worktrees and must never be committed.
if ! grep -qxF ".worktrees/" "$TARGET_REPO/.gitignore" 2>/dev/null; then
  log "Adding .worktrees/ to .gitignore"
  [ "$DRY_RUN" = "1" ] || echo ".worktrees/" >> "$TARGET_REPO/.gitignore"
fi

if [ "$DRY_RUN" != "1" ] && [ -n "$(git -C "$TARGET_REPO" status --porcelain -- .ecc .gitignore)" ]; then
  log "Committing .ecc/memory and .gitignore so task worktrees start with them"
  git -C "$TARGET_REPO" add .ecc .gitignore
  git -C "$TARGET_REPO" commit -q -m "Add shared agent memory (.ecc/memory)"
fi
