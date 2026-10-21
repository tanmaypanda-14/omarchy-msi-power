#!/bin/bash
# One-shot setup for the MSI Center summary widget: grant the msi-ec group
# write access to exactly the seven attributes the app writes, so the widget
# controls the board directly. Same permissions as the msi-center package.
#
#   sudo setup/grant-msi-ec-access.sh            # grants the invoking user
#   sudo setup/grant-msi-ec-access.sh alice      # grants a named user
#
# Safe to re-run (idempotent). After it finishes start a NEW login session
# (log out/in or reboot) so your process gains the msi-ec group; verify with:
#   getent group msi-ec

set -e

if [ "$(id -u)" -ne 0 ]; then
  echo "error: run as root (sudo $0)" >&2
  exit 1
fi

me="$(readlink -f "$0")"
dir="$(dirname "$me")"
target="${1:-${SUDO_USER:-root}}"

echo "==> creating the msi-ec group"
getent group msi-ec >/dev/null || groupadd --system msi-ec

echo "==> adding '$target' to the msi-ec group"
usermod -a -G msi-ec "$target"

echo "==> installing udev rule"
install -m 0644 "$dir/90-msi-ec.rules" /etc/udev/rules.d/90-msi-ec.rules

echo "==> enabling the msi-ec driver and the raw EC interface"
install -D -m 0644 "$dir/modules-load.conf" /etc/modules-load.d/msi-ec.conf
install -D -m 0644 "$dir/msi-ec-tmpfiles.conf" /etc/tmpfiles.d/msi-ec.conf
# write_support=0: the widget only reads the tachometer. Nothing in this
# plugin writes raw EC registers any more.
install -D -m 0644 "$dir/ec-sys.conf" /etc/modprobe.d/msi-ec.conf
modprobe msi_ec 2>/dev/null || true
modprobe ec_sys 2>/dev/null || true

echo "==> removing the old fan-curve helper"
# Earlier versions installed a root scoped curve writer. The widget now uses
# only the app's sysfs interface, so neither the sudoers rule nor the script
# should stay behind.
rm -f /etc/sudoers.d/omarchy-msi-fan-curve /usr/local/bin/omarchy-msi-fan-curve

echo "==> reloading udev rules and re-triggering the MSI devices"
udevadm control --reload-rules
udevadm trigger /sys/devices/platform/msi-ec 2>/dev/null || true
udevadm trigger /sys/class/leds/msiacpi::kbd_backlight 2>/dev/null || true
udevadm trigger /sys/class/power_supply/BAT1 2>/dev/null || true

# Apply immediately as well, so a re-login alone is enough (udev async RUN is
# not guaranteed to have landed yet). Allowlist only — never -R g+w.
echo "==> applying permissions now"
mec=/sys/devices/platform/msi-ec
bat=/sys/class/power_supply/BAT1
kbd=/sys/class/leds/msiacpi::kbd_backlight
if [ -d "$mec" ]; then
  chgrp -R msi-ec "$mec" 2>/dev/null || true
  chmod -R g-w "$mec" 2>/dev/null || true
  chmod g+w "$mec/shift_mode" "$mec/fan_mode" "$mec/cooler_boost" \
            "$mec/webcam_block" "$mec/win_key" 2>/dev/null || true
fi
if [ -d "$bat" ]; then
  chgrp -R msi-ec "$bat" 2>/dev/null || true
  chmod -R g-w "$bat" 2>/dev/null || true
  chmod g+w "$bat/charge_control_end_threshold" 2>/dev/null || true
fi
if [ -e "$kbd/brightness" ]; then
  chgrp msi-ec "$kbd/brightness" 2>/dev/null || true
  chmod g+w "$kbd/brightness" 2>/dev/null || true
fi
# Raw EC interface: group READ-ONLY (mode 640 — never g+w).
systemd-tmpfiles --create /etc/tmpfiles.d/msi-ec.conf 2>/dev/null || true

echo
echo "current permissions:"
for f in "$mec/shift_mode" "$mec/fan_mode" "$mec/webcam_block" \
         "$bat/charge_control_end_threshold" "$kbd/brightness"; do
  [ -e "$f" ] && ls -l "$f"
done
[ -e /sys/kernel/debug/ec/ec0/io ] && ls -l /sys/kernel/debug/ec/ec0/io
