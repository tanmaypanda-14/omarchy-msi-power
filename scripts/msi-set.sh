#!/bin/bash
# Apply a setting with the exact write msi-center performs: a plain sysfs
# write to the msi-ec attribute (or the battery/LED attribute) behind it.
# The udev rule grants the msi-ec group write access to just these files.
#
#   msi-set.sh shift   eco|comfort|sport
#   msi-set.sh fan     auto|silent|advanced
#   msi-set.sh cooler  on|off
#   msi-set.sh battery 50..100
#   msi-set.sh kbd     0..255
#   msi-set.sh fnswap  on|off
#   msi-set.sh webcam  on|off
#   msi-set.sh fanlevel 20..100
#   msi-set.sh fanrestore
#
# fanlevel/fanrestore are the one exception to "plain sysfs writes": the EC
# fan curve is not exported by msi-ec, so they go through the setuid
# msi-fan-helper that ships with msi-center. It accepts a speed, never an
# address, and only ever writes the seven curve speeds at 0x72..0x78.
#
# Exit code reflects whether the write landed; the next poll re-reads the EC.

set -u

MEC=/sys/devices/platform/msi-ec
BAT=/sys/class/power_supply/BAT1
KBD=/sys/class/leds/msiacpi::kbd_backlight

# msi-center's setuid helper: /usr/bin from the package, /usr/local/bin from
# the release tarball. Empty when manual fan speed is not installed.
HELPER=""
for cand in /usr/bin/msi-fan-helper /usr/local/bin/msi-fan-helper; do
  [ -x "$cand" ] && HELPER=$cand && break
done

usage() {
  cat >&2 <<'EOF'
usage: msi-set.sh <setting> <value>
  shift   eco|comfort|sport
  fan     auto|silent|advanced
  cooler  on|off
  battery 50..100
  kbd     0..255
  fnswap  on|off
  webcam  on|off
  fanlevel 20..100
  fanrestore
EOF
}

bool() {
  case "${1:-}" in
    on|true|1|yes)  echo on ;;
    off|false|0|no) echo off ;;
    *) echo "" ;;
  esac
}

setting=${1:-}
value=${2:-}
target=""

case "$setting" in
  shift)
    target="$MEC/shift_mode"
    case "$value" in eco|comfort|sport) ;; *) echo "error: bad shift mode '$value'" >&2; exit 2;; esac
    ;;
  fan)
    target="$MEC/fan_mode"
    case "$value" in auto|silent|advanced) ;; *) echo "error: bad fan mode '$value'" >&2; exit 2;; esac
    ;;
  cooler)
    target="$MEC/cooler_boost"
    value=$(bool "$value") || true
    ;;
  webcam)
    target="$MEC/webcam_block"
    value=$(bool "$value") || true
    ;;
  fnswap)
    target="$MEC/win_key"
    case "$(bool "$value")" in
      on)  value=left ;;
      off) value=right ;;
      *)   echo "error: bad value '$2' (use on|off)" >&2; exit 2 ;;
    esac
    ;;
  battery)
    target="$BAT/charge_control_end_threshold"
    case "$value" in ''|*[!0-9]*) echo "error: bad charge limit '$value'" >&2; exit 2;; esac
    if [ "$value" -lt 50 ] || [ "$value" -gt 100 ]; then
      echo "error: charge limit must be 50-100" >&2; exit 2
    fi
    ;;
  kbd)
    target="$KBD/brightness"
    case "$value" in ''|*[!0-9]*) echo "error: bad brightness '$value'" >&2; exit 2;; esac
    if [ "$value" -gt 255 ]; then
      echo "error: brightness must be 0-255" >&2; exit 2
    fi
    ;;
  fanlevel)
    case "$value" in ''|*[!0-9]*) echo "error: bad fan speed '$value'" >&2; exit 2;; esac
    if [ "$value" -lt 20 ] || [ "$value" -gt 100 ]; then
      echo "error: manual fan speed must be 20-100" >&2; exit 2
    fi
    if [ -z "$HELPER" ]; then
      echo "error: msi-fan-helper is missing (reinstall msi-center)" >&2; exit 1
    fi
    exec "$HELPER" manual "$value"
    ;;
  fanrestore)
    if [ -z "$HELPER" ]; then
      echo "error: msi-fan-helper is missing (reinstall msi-center)" >&2; exit 1
    fi
    # The app archives the curve it found before the first override; fall back
    # to the curve this EC shipped with.
    curve=0,50,60,65,75,75,100
    state=${XDG_STATE_HOME:-$HOME/.local/state}/msi-center/fan-curve.orig
    if [ -r "$state" ] && read -r saved < "$state" && [ -n "$saved" ]; then
      curve=$saved
    fi
    exec "$HELPER" curve "$curve"
    ;;
  *)
    usage
    exit 2
    ;;
esac

if [ -z "$value" ] || [ -z "$target" ]; then
  echo "error: bad value for '$setting'" >&2
  usage
  exit 2
fi
if [ ! -e "$target" ]; then
  echo "error: $target does not exist (not exposed by this EC)" >&2
  exit 1
fi
if [ ! -w "$target" ]; then
  echo "error: $target is not writable by $(id -un)" >&2
  echo "install msi-center (which ships the udev rule) or run this widget's" >&2
  echo "setup/grant-msi-ec-access.sh once, then log out and back in." >&2
  exit 1
fi

printf '%s' "$value" > "$target" || {
  echo "error: write to $target failed" >&2
  exit 1
}
