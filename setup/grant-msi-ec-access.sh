#!/bin/bash
# One-shot setup for the MSI Center summary widget: grant the msi-ec group
# write access to exactly the seven attributes the app writes.
#
#   sudo setup/grant-msi-ec-access.sh            # grants the invoking user
#   sudo setup/grant-msi-ec-access.sh alice      # grants a named user
#
# If the msi-center package is installed, its system integration is used and
# this script only adds the group membership, removes older duplicate files
# and re-applies the grants. Without the package it installs the standalone
# copies from this directory under distinct msi-power names, so a later
# package install never has to fight a shadowing /etc file.
#
# Safe to re-run (idempotent). After the first run log out and back in so your
# process gains the msi-ec group; verify with:  getent group msi-ec

set -e

if [ "$(id -u)" -ne 0 ]; then
  echo "error: run as root (sudo $0)" >&2
  exit 1
fi

me="$(readlink -f "$0")"
dir="$(dirname "$me")"
target="${1:-${SUDO_USER:-root}}"

pkg_rules=/usr/lib/udev/rules.d/99-msi-ec-permissions.rules
pkg_unit=/usr/lib/systemd/system/msi-ec-perms.service
pkg_tmpfiles=/usr/lib/tmpfiles.d/msi-ec.conf
have_pkg=0
if [ -f "$pkg_rules" ] && [ -f "$pkg_unit" ]; then
  have_pkg=1
fi

echo "==> creating the msi-ec group"
getent group msi-ec >/dev/null || groupadd --system msi-ec

echo "==> adding '$target' to the msi-ec group"
usermod -a -G msi-ec "$target"

# Files written by older versions of this plugin, plus /etc copies that would
# shadow the package's /usr/lib files. Removing them is what makes the setup
# single-sourced.
legacy=(
  /etc/udev/rules.d/90-msi-ec.rules
  /etc/udev/rules.d/99-msi-ec-permissions.rules
  /etc/modprobe.d/msi-ec.conf
  /etc/modules-load.d/msi-ec.conf
  /etc/tmpfiles.d/msi-ec.conf
  /etc/systemd/system/msi-ec-perms.service
)

if [ "$have_pkg" -eq 1 ]; then
  echo "==> msi-center package integration found; using it (no duplicate files)"
  systemctl disable --now msi-power-perms.service 2>/dev/null || true
  legacy+=(
    /etc/udev/rules.d/90-msi-power.rules
    /etc/modprobe.d/msi-power.conf
    /etc/modules-load.d/msi-power.conf
    /etc/tmpfiles.d/msi-power.conf
    /etc/systemd/system/msi-power-perms.service
  )
  tmpfiles="$pkg_tmpfiles"
else
  echo "==> no msi-center package; installing the standalone msi-power files"
  tmpfiles=/etc/tmpfiles.d/msi-power.conf
  install -D -m 0644 "$dir/90-msi-power.rules" /etc/udev/rules.d/90-msi-power.rules
  install -D -m 0644 "$dir/msi-power-modules-load.conf" /etc/modules-load.d/msi-power.conf
  install -D -m 0644 "$dir/msi-power-modprobe.conf" /etc/modprobe.d/msi-power.conf
  install -D -m 0644 "$dir/msi-power-tmpfiles.conf" "$tmpfiles"
  install -D -m 0644 "$dir/msi-power-perms.service" /etc/systemd/system/msi-power-perms.service
fi

echo "==> removing legacy files"
rm -f "${legacy[@]}"

echo "==> removing the old fan-curve helper"
rm -f /etc/sudoers.d/omarchy-msi-fan-curve /usr/local/bin/omarchy-msi-fan-curve

echo "==> loading the EC driver and the read-only raw EC interface"
modprobe msi_ec 2>/dev/null || true
modprobe ec_sys 2>/dev/null || true

echo "==> enabling the permission unit"
systemctl daemon-reload
if [ "$have_pkg" -eq 1 ]; then
  systemctl enable msi-ec-perms.service 2>/dev/null || true
  systemd-tmpfiles --create "$pkg_tmpfiles" 2>/dev/null || true
  systemctl restart msi-ec-perms.service 2>/dev/null || true
else
  systemctl enable msi-power-perms.service 2>/dev/null || true
  systemd-tmpfiles --create "$tmpfiles" 2>/dev/null || true
  systemctl restart msi-power-perms.service 2>/dev/null || true
fi

echo "==> reloading udev rules and re-triggering the MSI devices"
udevadm control --reload-rules
for p in /sys/devices/platform/msi-ec \
         /sys/class/leds/msiacpi::kbd_backlight \
         /sys/class/power_supply/BAT1; do
  [ -e "$p" ] && udevadm trigger --action=change "$p" 2>/dev/null || true
done
udevadm settle 2>/dev/null || true

# Apply immediately as well, so a re-login alone is enough. Allowlist only —
# never a recursive chgrp. The udev rule and the unit are the durable paths.
echo "==> applying permissions now"
mec=/sys/devices/platform/msi-ec
bat=/sys/class/power_supply/BAT1
kbd=/sys/class/leds/msiacpi::kbd_backlight
if [ -d "$mec" ]; then
  chmod -R g-w "$mec" 2>/dev/null || true
  for f in shift_mode fan_mode cooler_boost webcam_block win_key; do
    [ -e "$mec/$f" ] || continue
    chgrp msi-ec "$mec/$f" 2>/dev/null || true
    chmod g+w "$mec/$f" 2>/dev/null || true
  done
fi
if [ -d "$bat" ]; then
  chmod -R g-w "$bat" 2>/dev/null || true
  if [ -e "$bat/charge_control_end_threshold" ]; then
    chgrp msi-ec "$bat/charge_control_end_threshold" 2>/dev/null || true
    chmod g+w "$bat/charge_control_end_threshold" 2>/dev/null || true
  fi
fi
if [ -e "$kbd/brightness" ]; then
  chgrp msi-ec "$kbd/brightness" 2>/dev/null || true
  chmod g+w "$kbd/brightness" 2>/dev/null || true
fi

# Raw EC: read-only, traverse-only directories (0710). This is the fallback
# for the unit/hook; applying it here also fixes a running session at once.
if [ -e /sys/kernel/debug/ec/ec0/io ]; then
  chgrp msi-ec /sys/kernel/debug /sys/kernel/debug/ec /sys/kernel/debug/ec/ec0 \
    /sys/kernel/debug/ec/ec0/io 2>/dev/null || true
  chmod 0710 /sys/kernel/debug /sys/kernel/debug/ec /sys/kernel/debug/ec/ec0 2>/dev/null || true
  chmod 0640 /sys/kernel/debug/ec/ec0/io 2>/dev/null || true
fi

echo
echo "current permissions:"
for f in "$mec/shift_mode" "$mec/fan_mode" "$mec/cooler_boost" \
         "$mec/webcam_block" "$mec/win_key" \
         "$bat/charge_control_end_threshold" "$kbd/brightness"; do
  [ -e "$f" ] && ls -l "$f"
done
[ -e /sys/kernel/debug/ec/ec0/io ] && ls -l /sys/kernel/debug/ec/ec0/io

echo
echo "done. If '$target' was just added to msi-ec, log out and back in."
echo "Fan RPM will appear once the new session is running."
