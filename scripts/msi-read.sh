#!/bin/bash
# Read-only snapshot of the MSI EC state, mirroring the msi-center app's
# dashboard: CPU temperature, fan speed and level, battery and charge limit,
# power/fan modes, keyboard backlight, Fn/Win swap, webcam block. Also reports
# host-level read-only stats shown next to the EC sensors: average CPU clock,
# GPU clock and RAM usage.
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

# Raw EC image: used for the fan tachometer (msi-ec does not export it on the
# installed driver, 0.13) and for the fan-curve speed points at 0x72..0x78.
# Newer builds expose debug/ec_dump, but this file stays the common path.
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

# fanmanual — is the fan curve currently a flat, manually chosen one?
#
# Reads the seven speed points at 0x72..0x78 from the raw EC image (the same
# read-only image used for the tachometer). "manualFan" is the fixed speed,
# or -1 when the EC curve is in charge. hasManualFan says whether an override
# can be written at all: it needs msi-center's setuid helper and the driver's
# debug/ec_set node (msi-ec loaded with debug=1).
fanmanual() {
  local helper="" cand set=$MEC/debug/ec_set
  local bytes first i flat=1
  local -a sp

  for cand in /usr/bin/msi-fan-helper /usr/local/bin/msi-fan-helper; do
    [ -x "$cand" ] && helper=$cand && break
  done

  if [ -z "$helper" ] || [ ! -e "$set" ] || [ -z "$ECIO" ]; then
    printf '"manualFan":-1,"hasManualFan":0'
    return
  fi

  bytes=$(dd if="$ECIO" bs=1 skip=114 count=7 2>/dev/null | od -An -tu1)
  read -ra sp <<< "$bytes"
  if [ "${#sp[@]}" -ne 7 ]; then
    printf '"manualFan":-1,"hasManualFan":0'
    return
  fi

  first=${sp[0]}
  for i in 1 2 3 4 5 6; do
    [ "${sp[i]}" -eq "$first" ] || flat=0
  done

  # The table is only consulted in advanced mode; auto/silent use the EC's own
  # logic even when the stored points happen to be flat.
  if [ "$flat" -eq 1 ] && [ "$(txt "$MEC/fan_mode" "")" = "advanced" ]; then
    printf '"manualFan":%d,"hasManualFan":1' "$first"
  else
    printf '"manualFan":-1,"hasManualFan":1'
  fi
}

# cpuclock — average current clock of the online CPUs, in MHz (-1 when the
# kernel exposes no cpufreq policy). scaling_cur_freq is in kHz.
cpuclock() {
  local f v sum=0 n=0
  for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do
    [ -r "$f" ] || continue
    v=$(<"$f") || continue
    v=${v%%[!0-9]*}
    [ -n "$v" ] || continue
    sum=$((sum + v))
    n=$((n + 1))
  done
  if [ "$n" -gt 0 ]; then printf '%d' $((sum / n / 1000)); else printf '%d' -1; fi
}

# gpuclock — amdgpu's hwmon freq1_input is in Hz; report the first GPU that
# exposes a clock (-1 when there is none, e.g. NVIDIA-only machines).
gpuclock() {
  local f v
  for f in /sys/class/drm/card*/device/hwmon/hwmon*/freq1_input; do
    [ -r "$f" ] || continue
    v=$(<"$f") || continue
    v=${v%%[!0-9]*}
    [ -n "$v" ] && { printf '%d' $((v / 1000000)); return; }
  done
  printf '%d' -1
}

# ramusage — used = MemTotal - MemAvailable, the same number `free` reports.
# Values are in kB; both are -1 when /proc/meminfo cannot be read.
ramusage() {
  local key val total=-1 avail=-1
  if [ -r /proc/meminfo ]; then
    while read -r key val _; do
      case "$key" in
        MemTotal:)     total=$val ;;
        MemAvailable:) avail=$val ;;
      esac
    done < /proc/meminfo
  fi
  if [ "$total" -gt 0 ] && [ "$avail" -ge 0 ]; then
    printf '"ramUsedKb":%d,"ramTotalKb":%d' $((total - avail)) "$total"
  else
    printf '"ramUsedKb":-1,"ramTotalKb":-1'
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
printf '%s,' "$(fanmanual)"
printf '"battery":%s,' "$(num "$BAT/capacity" -1)"
printf '"batteryLimit":%s,' "$(num "$BAT/charge_control_end_threshold" -1)"
printf '"kbdLevel":%s,' "$(num "$KBD/brightness" -1)"
printf '"kbdMax":%s,' "$(num "$KBD/max_brightness" 0)"
printf '"webcamBlocked":%s,' "$(bool "$MEC/webcam_block" off)"
printf '"fnSwap":%s,' "$([ "$(txt "$MEC/win_key" "")" = "left" ] && printf 1 || printf 0)"
printf '%s,' "$(fanrpm)"
printf '"cpuMhz":%s,"gpuMhz":%s,' "$(cpuclock)" "$(gpuclock)"
printf '%s,' "$(ramusage)"
printf '"hasCooler":%s,' "$(avail "$MEC/cooler_boost")"
printf '"hasWebcam":%s,' "$(avail "$MEC/webcam_block")"
printf '"hasFnSwap":%s,' "$(avail "$MEC/win_key")"
printf '"hasKbd":%s}\n' "$(avail "$KBD/brightness")"
