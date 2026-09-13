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
#   msi-set.sh fan auto
#   msi-set.sh cooler 1
#   msi-set.sh kbd 2
#   msi-set.sh end 80
#
# Exit code reflects whether the write landed; sysfs stays the source of truth
# (state is re-read on the next poll either way).

set -u

MEC=/sys/devices/platform/msi-ec
LED=/sys/class/leds/msiacpi::kbd_backlight
PSU=/sys/class/power_supply
# Raw EC register file for the USB power-share bit (msi-ec sysfs does not
# export it). Group-writable after setup/grant-msi-ec-access.sh.
ECIO=""
for cand in /dev/ec /sys/kernel/debug/ec/ec0/io; do
  [ -e "$cand" ] && ECIO=$cand && break
done

# bool <value> — msi-ec booleans are "on"/"off"; accept the wrappers used elsewhere.
bool() {
  case "${1:-off}" in
    on|true|1|yes) echo on  ;;
    off|false|0|no) echo off ;;
    *)             echo off ;;
  esac
}
# isint <value> — reject anything that isn't a plain non-negative integer.
isint() { [[ "$1" =~ ^[0-9]+$ ]]; }

usage() {
  echo "usage: msi-set.sh <shift|fan|cooler|webcam|block|fnkey|winkey|kbd|end|start|usb> <value>" >&2
}

client=${1:-}
value=${2:-}
target=

case "$client" in
  shift)  target="$MEC/shift_mode" ;;
  fan)    target="$MEC/fan_mode" ;;
  cooler) target="$MEC/cooler_boost"; value=$(bool "$value") ;;
  webcam) target="$MEC/webcam";          value=$(bool "$value") ;;
  block)  target="$MEC/webcam_block";    value=$(bool "$value") ;;
  fnkey)  target="$MEC/fn_key";  [[ "$value" == left || "$value" == right ]] || value= ;;
  winkey) target="$MEC/win_key"; [[ "$value" == left || "$value" == right ]] || value= ;;
  kbd)    target="$LED/brightness"; isint "$value" || value= ;;
  end)    target="$PSU/BAT1/charge_control_end_threshold";   isint "$value" || value= ;;
  start)  target="$PSU/BAT1/charge_control_start_threshold"; isint "$value" || value= ;;
  usb)    target=""; value=$(bool "$value"); true ;; # handled below
  *)
    usage
    exit 2
    ;;
esac

# USB power share: raw EC byte 0xbf, MControlCenter semantics (0x28 on, 0x08
# off), matching the legacy helper so results are identical. Refuse to write
# unless the byte is already one of those two states — writing a register that
# holds something else would clobber a feature we don't understand.
if [ "$client" = "usb" ]; then
  if [ -z "$ECIO" ]; then
    echo "error: no raw EC interface (/dev/ec or ec_sys debugfs io)" >&2
    exit 1
  fi
  if [ ! -w "$ECIO" ]; then
    self="$(readlink -f "$0" 2>/dev/null)"
    grant="${self%/scripts/*}/setup/grant-msi-ec-access.sh"
    echo "error: $ECIO is not writable" >&2
    echo "grant the widget write access once (adds the ec_sys interface):" >&2
    echo "  sudo ${grant}" >&2
    echo "  # then log out and back in, or reboot" >&2
    exit 1
  fi
  cur=$(dd if="$ECIO" bs=1 skip=191 count=1 2>/dev/null | od -An -tu1 | tr -d ' \n')
  want=8
  [ "$value" = "on" ] && want=40
  if [ "$cur" != "8" ] && [ "$cur" != "40" ]; then
    echo "error: EC byte 0xbf does not hold a USB power-share state (0x$cur); refusing to write" >&2
    exit 1
  fi
  printf "\\$(printf '%03o' "$want")" | dd of="$ECIO" bs=1 seek=191 conv=notrunc 2>/dev/null || {
    echo "error: write to $ECIO failed" >&2
    exit 1
  }
  exit 0
fi

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