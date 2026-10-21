#!/bin/bash
# Read-only snapshot of the MSI EC state, mirroring the msi-center app's
# dashboard: CPU temperature, fan speed and level, battery and charge limit,
# power/fan modes, keyboard backlight, Fn/Win swap, webcam block.
#
# Every value comes from sysfs, which is world-readable, so reporting needs
# no privileges. Output is one line of JSON; when msi-ec is absent the whole
# payload is {"present":0} and the widget hides itself.

set -u

MEC=/sys/devices/platform/msi-ec
PSU=/sys/class/power_supply
BAT=$PSU/BAT1
ADP=$PSU/ADP1
KBD=/sys/class/leds/msiacpi::kbd_backlight
DMI=/sys/class/dmi/id

# Raw EC image: only used for the fan tachometer, which msi-ec does not
# export on the installed driver (0.13). Newer builds expose debug/ec_dump.
ECIO=""
for cand in /sys/kernel/debug/ec/ec0/io /dev/ec; do
  [ -r "$cand" ] && ECIO=$cand && break
done

if [ ! -d "$MEC" ]; then
  printf '{"present":0}\n'
  exit 0
fi

# readtrim <path> <varname> — contents minus surrounding whitespace.
readtrim() {
  [ -r "$1" ] || { printf -v "$2" '%s' ""; return 1; }
  local _v
  _v=$(<"$1") || _v=""
  _v=${_v#"${_v%%[![:space:]]*}"}
  _v=${_v%"${_v##*[![:space:]]}"}
  printf -v "$2" '%s' "$_v"
}
# txt <path> [fallback]
txt() { local v; readtrim "$1" v; if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "${2:-}"; fi; }
# num <path> [fallback] — first non-negative int token; fallback only when
# the attribute is missing, so a real zero (fan stopped) stays 0.
num() {
  [ -r "$1" ] || { printf '%s' "${2:-}"; return; }
  local v; readtrim "$1" v
  v=${v%%[!0-9]*}
  while [ "${v#0}" != "$v" ]; do v=${v#0}; done
  [ -n "$v" ] && printf '%s' "$v" || printf '0'
}
# bool <path> [fallback] — msi-ec booleans are "on"/"off".
bool() { case "$(txt "$1" "${2:-}")" in 1|on|true|enabled) printf 1;; *) printf 0;; esac; }
# list <path> — sysfs newline list as a JSON array.
list() {
  local out="" tok ls
  readtrim "$1" ls
  if [ -z "$ls" ]; then printf '[]'; return; fi
  while IFS= read -r tok; do
    [ -n "$tok" ] && out="$out\"${tok}\","
  done <<< "$ls"
  printf '[%s]' "${out%,}"
}
# avail <path> — 1 when the attribute exists.
avail() { [ -e "$1" ] && printf 1 || printf 0; }
# jsonstr <text> — escape the two characters that matter for these values.
jsonstr() { local s=${1//\\/\\\\}; printf '%s' "${s//\"/\\\"}"; }

# fanrpm — exact same two sources, in the same order, as msi-center:
#   1. msi-ec's debug/ec_dump row 0xc_ (newer drivers, no ec_sys needed)
#   2. the raw EC image at 0xCC/0xCD (installed 0.13)
# RPM = 480000 / ticks (16-bit big-endian), 0 when the fan is stopped.
fanrpm() {
  local ticks="" dump=$MEC/debug/ec_dump row addr cells
  local -a b

  if [ -r "$dump" ]; then
    row=$(grep -m1 '^| 0xc_ |' "$dump" 2>/dev/null) || row=""
    if [ -n "$row" ]; then
      IFS='|' read -r _ addr cells _ <<< "$row"
      read -ra b <<< "$cells"
      if [ "${#b[@]}" -ge 16 ]; then
        case "${b[12]}${b[13]}" in
          *[!0-9a-fA-F]*) ;;
          *) ticks=$(( 16#${b[12]} * 256 + 16#${b[13]} )) ;;
        esac
      fi
    fi
  fi

  if [ -z "$ticks" ] && [ -n "$ECIO" ]; then
    local pair hi lo
    pair=$(dd if="$ECIO" bs=1 skip=204 count=2 2>/dev/null | od -An -tu1)
    read -r hi lo <<< "$pair"
    case "$hi" in ''|*[!0-9]*) hi=0;; esac
    case "$lo" in ''|*[!0-9]*) lo=0;; esac
    ticks=$(( hi * 256 + lo ))
  fi

  if [ -n "$ticks" ] && [ "$ticks" -gt 0 ] && [ $((480000 / ticks)) -le 15000 ]; then
    printf '"fanRpm":%d,"hasFanRpm":1' $((480000 / ticks))
  elif [ -n "$ticks" ]; then
    printf '"fanRpm":0,"hasFanRpm":1'
  else
    printf '"fanRpm":0,"hasFanRpm":0'
  fi
}

printf '{"present":1,'
printf '"model":"%s",' "$(jsonstr "$(txt "$DMI/product_name" "")")"
printf '"ecFirmware":"%s",' "$(jsonstr "$(txt "$MEC/fw_version" "")")"
printf '"acOnline":%s,' "$(num "$ADP/online" 0)"
printf '"shiftModes":%s,' "$(list "$MEC/available_shift_modes")"
printf '"shiftMode":"%s",' "$(txt "$MEC/shift_mode" "")"
printf '"fanModes":%s,' "$(list "$MEC/available_fan_modes")"
printf '"fanMode":"%s",' "$(txt "$MEC/fan_mode" "")"
printf '"coolerBoost":%s,' "$(bool "$MEC/cooler_boost" off)"
printf '"cpuTemp":%s,' "$(num "$MEC/cpu/realtime_temperature" -1)"
printf '"fanLevel":%s,' "$(num "$MEC/cpu/realtime_fan_speed" -1)"
printf '"battery":%s,' "$(num "$BAT/capacity" -1)"
printf '"batteryLimit":%s,' "$(num "$BAT/charge_control_end_threshold" -1)"
printf '"kbdLevel":%s,' "$(num "$KBD/brightness" -1)"
printf '"kbdMax":%s,' "$(num "$KBD/max_brightness" 0)"
printf '"webcamBlocked":%s,' "$(bool "$MEC/webcam_block" off)"
printf '"fnSwap":%s,' "$([ "$(txt "$MEC/win_key" "")" = "left" ] && printf 1 || printf 0)"
printf '%s,' "$(fanrpm)"
printf '"hasCooler":%s,' "$(avail "$MEC/cooler_boost")"
printf '"hasWebcam":%s,' "$(avail "$MEC/webcam_block")"
printf '"hasFnSwap":%s,' "$(avail "$MEC/win_key")"
printf '"hasKbd":%s}\n' "$(avail "$KBD/brightness")"
