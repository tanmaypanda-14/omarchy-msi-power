#!/bin/bash
# Lifecycle hook for `omarchy plugin add` / `omarchy plugin update`: apply the
# root-side access grants (group, udev rule, boot-time driver/grant configs).
#
# Idempotent — safe to run any number of times. It re-executes the bundled
# grant script through sudo; on a non-interactive terminal (e.g. a CI-ish
# `omarchy plugin add --yes`) it cannot prompt and just explains the manual
# step, exiting 0 so the plugin itself still installs.
#
#   setup/install.sh                       # as your user (may prompt for sudo)

set -euo pipefail

dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
grant="$dir/grant-msi-ec-access.sh"

if [[ $EUID -ne 0 ]]; then
  sudo "$grant" "$@"
  rc=$?
  if (( rc != 0 )); then
    echo "setup/install.sh: could not run the grant as root (exit $rc)." >&2
    echo "  run it manually once:  sudo \"$grant\"" >&2
  fi
  exit 0
fi

exec "$grant" "$@"