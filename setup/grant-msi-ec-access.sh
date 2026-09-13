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
# verify with:  getent group msi-ec

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

echo "==> enabling the msi-ec driver and the ec_sys interface"
# msi_ec must be loaded (it is not auto-loaded on boot by the DKMS package),
# and ec_sys places the raw EC register file under debugfs that udev never
# sees, so perms are re-applied at boot with tmpfiles instead of a rule. Both
# modules are preloaded via modules-load.d — no daemon needed.
install -D -m 0644 "$dir/msi-ec-tmpfiles.conf" /etc/tmpfiles.d/msi-ec.conf
install -D -m 0644 "$dir/ec_sys-modprobe.conf" /etc/modprobe.d/msi-ec.conf
install -D -m 0644 "$dir/modules-load.conf" /etc/modules-load.d/msi-ec.conf
modprobe msi_ec 2>/dev/null || true
modprobe ec_sys 2>/dev/null || true

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

# Raw EC register files (USB power share). tmpfiles re-applies at boot;
# apply right now too so a re-login is all that's needed. The debugfs tree
# starts root-only, so the parent dir must become group-traversable as well.
if [ -d /sys/kernel/debug/ec ]; then
  chown -R root:msi-ec /sys/kernel/debug/ec 2>/dev/null || true
  chmod -R g+rwX /sys/kernel/debug/ec 2>/dev/null || true
fi
for io in /dev/ec /sys/kernel/debug/ec/ec0/io; do
  if [ -e "$io" ]; then
    chown root:msi-ec "$io" 2>/dev/null || true
    chmod g+rw "$io" 2>/dev/null || true
  fi
done

echo
echo "current permissions:"
for f in /sys/devices/platform/msi-ec/shift_mode \
         /sys/devices/platform/msi-ec/fan_mode \
         /sys/kernel/debug/ec/ec0/io; do
  if [ -e "$f" ]; then ls -l "$f"; fi
done

echo
echo "done. Log out and back in (or reboot) so '$target' picks up the msi-ec"
echo "group, then verify with:  getent group msi-ec   (and:  id "$target")"