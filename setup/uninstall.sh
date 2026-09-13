#!/bin/bash
# Lifecycle hook for `omarchy plugin remove`: undo everything
# setup/grant-msi-ec-access.sh installed — the udev rule, the boot-time
# modules-load/tmpfiles configs, the (obsolete) modprobe leftover, the
# debugfs permissions, and finally the msi-ec group.
#
# Idempotent. Elevation: interactive terminal → sudo prompt; no terminal /
# agent-driven → pkexec (omarchy's GUI password dialog). If neither is
# possible it explains the manual step and exits 0 so the plugin can still be
# removed (grants simply stay until you run it).

set -uo pipefail

self="$(readlink -f "${BASH_SOURCE[0]}")"

if [ "$(id -u)" -ne 0 ]; then
  if [[ -t 0 && -t 1 ]]; then
    exec sudo "$self" "$@"
  fi
  if command -v pkexec >/dev/null 2>&1; then
    exec pkexec "$self" "$@"
  fi
  echo "setup/uninstall.sh: cannot get root (no interactive terminal and pkexec unavailable)." >&2
  echo "  run it manually to revoke the grants:  sudo \"$self\"" >&2
  exit 0
fi

echo "==> removing udev rule"
rm -f /etc/udev/rules.d/90-msi-ec.rules

echo "==> removing boot-time driver and grant configs"
rm -f /etc/modules-load.d/msi-ec.conf
rm -f /etc/tmpfiles.d/msi-ec.conf
rm -f /etc/modprobe.d/msi-ec.conf

echo "==> reloading udev and resetting the EC/peripheral permissions"
udevadm control --reload-rules
for p in /sys/devices/platform/msi-ec \
         /sys/class/leds/msiacpi::kbd_backlight \
         /sys/class/power_supply/BAT1; do
  [ -e "$p" ] && udevadm trigger "$p" 2>/dev/null || true
done
# Debugfs has no udev events: hand the raw-EC tree back to root.
chown -R root:root /sys/kernel/debug/ec 2>/dev/null || true
chmod -R 0700 /sys/kernel/debug/ec 2>/dev/null || true
chmod 0700 /sys/kernel/debug 2>/dev/null || true

echo "==> removing the msi-ec group (best effort; members must be gone)"
members=$(getent group msi-ec | cut -d: -f4 2>/dev/null)
if [ -n "$members" ]; then
  for user in ${members//,/ }; do
    gpasswd -d "$user" msi-ec >/dev/null 2>&1 || true
  done
fi
groupdel msi-ec 2>/dev/null && echo "   group 'msi-ec' deleted" || echo "   group kept (still in use by a session; it will vanish once everyone logs out)"

echo
echo "done. The widget no longer has access to the MSI EC or the fan tachometer."
echo "Any EC changes you made (power/fan modes, thresholds) persist on the EC itself."