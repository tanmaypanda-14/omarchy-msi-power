#!/bin/bash
# One-shot setup for the tanmay.msi-power widget: grant a user group-level
# write access to the MSI EC sysfs attributes so the widget controls the
# board directly. This makes the widget fully standalone — MControlCenter and
# its root D-Bus helper never need to run or even be installed.
#
#   sudo setup/grant-msi-ec-access.sh            # grants the invoking user
#   sudo setup/grant-msi-ec-access.sh alice      # grants a named user
#
# Safe to re-run (idempotent). After it finishes you must start a NEW login
# session (log out/in or reboot) so your process gains the msi-ec group;
# verify with:  id msi-ec

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

echo "==> reloading udev rules and re-triggering the MSI devices"
udevadm control --reload-rules
udevadm trigger /sys/devices/platform/msi-ec 2>/dev/null || true
udevadm trigger /sys/class/leds/msiacpi::kbd_backlight 2>/dev/null || true
udevadm trigger /sys/class/power_supply/BAT1 2>/dev/null || true

# Apply immediately as well, so a re-login alone is enough (udev async RUN is
# not guaranteed to have landed yet).
echo "==> applying permissions now"
chown -R root:msi-ec /sys/devices/platform/msi-ec 2>/dev/null || true
chmod -R g+w /sys/devices/platform/msi-ec 2>/dev/null || true
chown root:msi-ec /sys/class/leds/msiacpi::kbd_backlight/brightness 2>/dev/null || true
chmod g+w /sys/class/leds/msiacpi::kbd_backlight/brightness 2>/dev/null || true
chown -R root:msi-ec /sys/class/power_supply/BAT1 2>/dev/null || true
chmod -R g+w /sys/class/power_supply/BAT1 2>/dev/null || true

echo
echo "current permissions:"
for f in /sys/devices/platform/msi-ec/shift_mode \
         /sys/devices/platform/msi-ec/fan_mode; do
  if [ -e "$f" ]; then ls -l "$f"; fi
done

echo
echo "done. Log out and back in (or reboot) so '$target' joins the msi-ec group,"
echo "then verify with:  id msi-ec"