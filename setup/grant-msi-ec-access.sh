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

echo "==> enabling the msi-ec driver and the raw EC interface"
# The DKMS package does not auto-load msi_ec at boot, so it is preloaded via
# modules-load.d. The udev rule then re-applies the group perms whenever the
# platform device appears — no daemon needed. ec_sys provides the debugfs
# file used for the fan tachometer (read-only for the group) and for the
# MCC-style fan-curve writes (root only, via the scoped curve script —
# hence write_support=1 in the modprobe conf).
install -D -m 0644 "$dir/modules-load.conf" /etc/modules-load.d/msi-ec.conf
install -D -m 0644 "$dir/msi-ec-tmpfiles.conf" /etc/tmpfiles.d/msi-ec.conf
install -D -m 0644 "$dir/ec-sys-write.conf" /etc/modprobe.d/msi-ec.conf
modprobe msi_ec 2>/dev/null || true
modprobe ec_sys write_support=1 2>/dev/null || modprobe ec_sys 2>/dev/null || true

echo "==> installing the MCC-style fan-curve writer (root-owned, sudo-scoped)"
# Mirrors MControlCenter's root helper, narrowed to the 26 validated curve
# bytes: the widget calls it via `sudo -n ... apply ...` (no password —
# sudoers entry below allows exactly that command for the msi-ec group).
install -m 0755 "$dir/../scripts/msi-fan-curve.sh" /usr/local/bin/omarchy-msi-fan-curve
install -m 0440 "$dir/msi-fan-curve.sudoers" /etc/sudoers.d/omarchy-msi-fan-curve
if command -v visudo >/dev/null 2>&1; then visudo -c 2>/dev/null || true; fi

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
# Raw EC interface: group READ-ONLY (mode 640 — never g+w).
systemd-tmpfiles --create /etc/tmpfiles.d/msi-ec.conf 2>/dev/null || true

echo
echo "current permissions:"
for f in /sys/devices/platform/msi-ec/shift_mode \
         /sys/devices/platform/msi-ec/fan_mode; do
  if [ -e "$f" ]; then ls -l "$f"; fi
done
ls -ld /sys/kernel/debug /sys/kernel/debug/ec /sys/kernel/debug/ec/ec0 2>/dev/null
if [ -e /sys/kernel/debug/ec/ec0/io ]; then ls -l /sys/kernel/debug/ec/ec0/io; fi

echo
echo "done. Log out and back in (or reboot) so '$target' picks up the msi-ec"
echo "group, then verify with:  getent group msi-ec   (and:  id "$target")"