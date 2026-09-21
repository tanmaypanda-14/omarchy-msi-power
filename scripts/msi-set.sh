#!/bin/bash
# Apply an MSI EC setting by writing the sysfs attribute directly. Reverse
# engineering the MControlCenter root D-Bus helper (src/helper/msi-ec.cpp)
# shows every setter is a plain write() to a sysfs file; the D-Bus service
# only existed to run those writes as root. With the msi-ec driver's sysfs
# attributes made group-writable (see setup/grant-msi-ec-access.sh and
# setup/90-msi-ec.rules) this script writes in place, so no MControlCenter,
# no helper daemon, and no root process are ever involved.
#
#   msi-set.sh shift comfort
#   msi-set.sh fan advanced
#   msi-set.sh cooler 1
#
# Exit code reflects whether the write landed; sysfs stays the source of truth
# (state is re-read on the next poll either way).

set -u

MEC=/sys/devices/platform/msi-ec

# bool <value> — msi-ec booleans are "on"/"off"; accept the wrappers used elsewhere.
bool() {
  case "${1:-off}" in
    on|true|1|yes) echo on  ;;
    off|false|0|no) echo off ;;
    *)             echo off ;;
  esac
}

usage() {
  echo "usage: msi-set.sh <shift|fan|cooler> <value>" >&2
}

client=${1:-}
value=${2:-}
target=

case "$client" in
  shift)  target="$MEC/shift_mode" ;;
  fan)    target="$MEC/fan_mode" ;;
  cooler) target="$MEC/cooler_boost"; value=$(bool "$value") ;;
  *)
    usage
    exit 2
    ;;
esac

if [ -z "$value" ] || [ -z "$target" ]; then
  echo "error: bad value for $client" >&2
  usage
  exit 2
fi
if [ ! -e "$target" ]; then
  echo "error: $target does not exist" >&2
  exit 1
fi
if [ ! -w "$target" ]; then
  self="$(readlink -f "$0" 2>/dev/null)"
  grant="${self%/scripts/*}/setup/grant-msi-ec-access.sh"
  echo "error: $target is not writable" >&2
  echo "grant the widget write access once (no MControlCenter needed):" >&2
  echo "  sudo ${grant}" >&2
  echo "  # then log out and back in, or reboot (joins the msi-ec group)" >&2
  exit 1
fi

printf '%s' "$value" > "$target" || {
  echo "error: write to $target failed" >&2
  exit 1
}