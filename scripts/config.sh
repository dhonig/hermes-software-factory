#!/usr/bin/env bash
# Factory settings (factory.toml).
#
#   scripts/config.sh show                 effective value of every setting and where it came from
#   scripts/config.sh migrate [--force]    write factory.toml from factory.conf (factory.conf is left as is)
#   scripts/config.sh migrate --dry-run    print the factory.toml it would write
#   scripts/config.sh example              print factory.example.toml
. "$(dirname "$0")/../lib/common.sh"
eval "set -- $(strip_flags "$@")"
py() { python3 -I "$FACTORY_ROOT/lib/config.py" "$@"; }

case "${1:-show}" in
  show)
    log "Settings (${FACTORY_CONFIG_FILE:-defaults only}; environment overrides marked)"
    py show "$CONFIG_DIR" ;;
  migrate)
    [ -f "$CONFIG_DIR/factory.conf" ] || die "No factory.conf in $CONFIG_DIR to migrate."
    if [ "$DRY_RUN" = 1 ]; then
      py migrate "$CONFIG_DIR"
      exit 0
    fi
    force=""; [ "${2:-}" = --force ] && force=--force
    sum_before=$(cksum < "$CONFIG_DIR/factory.conf")
    py migrate "$CONFIG_DIR" --write $force
    [ "$(cksum < "$CONFIG_DIR/factory.conf")" = "$sum_before" ] || die "factory.conf changed during migration (it shouldn't)."
    log "Wrote $CONFIG_DIR/factory.toml. factory.conf is untouched but no longer read; delete it when you're happy."
    log "Check it with: ./factory.sh config show" ;;
  example) py example ;;
  *) die "usage: config.sh show | migrate [--force] [--dry-run] | example" ;;
esac
