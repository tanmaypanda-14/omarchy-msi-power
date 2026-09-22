#!/bin/bash
# Remember the last applied fan preset across reboots, MControlCenter
# loadSettings parity: MCC re-applies fan mode + curves on startup because
# the EC drops them on a cold boot (this board does too — mode and tables
# are gone after power-off, so without a restore the panel wakes up on
# whatever the firmware defaults to).
#
#   msi-preset-state.sh get              # prints quiet|balanced|performance or nothing
#   msi-preset-state.sh set performance  # remembers it (strictly validated)
#
# The file lives next to the plugin: updates keep it (untracked), remove
# forgets it. Runs as the user, no privileges needed.
set -u

dir="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"
file="$dir/../.last-preset"

case "${1:-get}" in
  get)
    [ -r "$file" ] && cat "$file" || true
    ;;
  set)
    case "${2:-}" in
      quiet|balanced|performance) printf '%s' "$2" > "$file" ;;
      *) echo "error: unknown preset '${2:-}' (want quiet|balanced|performance)" >&2; exit 2 ;;
    esac
    ;;
  *)
    echo "usage: $0 get|set <quiet|balanced|performance>" >&2
    exit 2
    ;;
esac
