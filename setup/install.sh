#!/bin/bash
# Lifecycle hook for `omarchy plugin add` / `omarchy plugin update`: apply the
# root-side access grants (group, udev rule, boot-time driver/grant configs).
#
# Idempotent — safe to run any number of times.
#
# Elevation: interactive terminal → sudo prompt; no terminal / agent-driven →
# pkexec, which pops omarchy's GUI password dialog. If neither is possible it
# explains the manual step and exits 0 so the plugin itself still installs.

set -euo pipefail

self="$(readlink -f "${BASH_SOURCE[0]}")"
dir="$(dirname "$self")"
grant="$dir/grant-msi-ec-access.sh"

# Captured before elevation: pkexec wipes SUDO_USER and sets HOME=/root.
invoker="${SUDO_USER:-${USER:-$(id -un)}}"

if [[ $EUID -ne 0 ]]; then
  if [[ -t 0 && -t 1 ]]; then
    exec sudo "$self" "$invoker"
  fi
  if command -v pkexec >/dev/null 2>&1; then
    exec pkexec "$self" "$invoker"
  fi
  echo "setup/install.sh: cannot get root (no interactive terminal and pkexec unavailable)." >&2
  echo "  run it manually once:  sudo \"$grant\" $invoker" >&2
  exit 0
fi

exec "$grant" "$invoker"