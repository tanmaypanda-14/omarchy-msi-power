#!/bin/bash
# Lifecycle hook for `omarchy plugin remove`: undo what this plugin installed.
#
# It always removes the plugin's own files (including the legacy 90-msi-ec /
# msi-ec.conf names from older versions). It only revokes the shared msi-ec
# group and the debugfs grant when the msi-center package is NOT installed —
# if the app is present, the widget was only a consumer of its integration.
#
# Idempotent. Elevation: interactive terminal → sudo prompt; no terminal /
# agent-driven → pkexec (omarchy's GUI password dialog). If neither is
# possible it explains the manual step and exits 0 so the plugin can still be
# removed.

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

pkg_rules=/usr/lib/udev/rules.d/99-msi-ec-permissions.rules
pkg_unit=/usr/lib/systemd/system/msi-ec-perms.service
have_pkg=0
if [ -f "$pkg_rules" ] && [ -f "$pkg_unit" ]; then
  have_pkg=1
fi

echo "==> removing this plugin's unit and rule"
systemctl disable --now msi-power-perms.service 2>/dev/null || true
rm -f /etc/systemd/system/msi-power-perms.service
rm -f /etc/udev/rules.d/90-msi-power.rules /etc/udev/rules.d/90-msi-ec.rules \
      /etc/udev/rules.d/99-msi-ec-permissions.rules

echo "==> removing this plugin's driver/grant configs"
rm -f /etc/modules-load.d/msi-power.conf /etc/modules-load.d/msi-ec.conf
rm -f /etc/tmpfiles.d/msi-power.conf /etc/tmpfiles.d/msi-ec.conf
rm -f /etc/modprobe.d/msi-power.conf /etc/modprobe.d/msi-ec.conf
rm -f /etc/systemd/system/msi-ec-perms.service
rm -f /etc/sudoers.d/omarchy-msi-fan-curve /usr/local/bin/omarchy-msi-fan-curve

systemctl daemon-reload 2>/dev/null || true
udevadm control --reload-rules 2>/dev/null || true
for p in /sys/devices/platform/msi-ec \
         /sys/class/leds/msiacpi::kbd_backlight \
         /sys/class/power_supply/BAT1; do
  [ -e "$p" ] && udevadm trigger --action=change "$p" 2>/dev/null || true
done

if [ "$have_pkg" -eq 1 ]; then
  echo "==> msi-center is still installed; keeping its group, unit and debugfs grant"
  udevadm settle 2>/dev/null || true
  echo
  echo "done. The widget is removed; the msi-center app keeps working."
  exit 0
fi

echo "==> resetting the EC and peripheral permissions"
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
