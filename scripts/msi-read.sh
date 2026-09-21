#!/bin/bash
# Read-only snapshot of the MSI Embedded Controller state this widget shows.
# Every value comes from sysfs, which is world-readable, so reporting needs
# no privileges and never touches the (now-removed) root helper.
#
# Output is one line of JSON. When the msi-ec driver is absent the whole
# payload is just {"present":0} and the bar widget hides itself.

set -u

MEC=/sys/devices/platform/msi-ec
PSU=/sys/class/power_supply
DMI=/sys/class/dmi/id
# Read-only raw EC register file (ec_sys debugfs io, or the acpi_ec device).
# Used only for the fan tachometer, which the msi-ec sysfs driver does not
# export. setup/grant-msi-ec-access.sh makes it group-READABLE (never
# writable); without it hasFanRpm=0 and the widget hides the row.
ECIO=""
for cand in /dev/ec /sys/kernel/debug/ec/ec0/io; do
  [ -r "$cand" ] && ECIO=$cand && break
done

if [ ! -d "$MEC" ]; then
  printf '{"present":0}\n'
  exit 0
fi

# readtrim <path> <varname> — file contents minus surrounding whitespace.
# Zero forks, zero execs: $(<...) is a bash optimization that reads without
# spawning a subshell, the stripping is parameter expansion, and printf -v
# assigns to the caller's variable (dynamic scope) without one either.
readtrim() {
  # Missing/unreadable -> empty output, nonzero exit (same contract trim had:
  # sed failed silently on a missing file). The [ -r ] pre-check is a builtin
  # stat; without it the failed open inside $(<...) would leak an error past
  # redirections, since expansion runs before the command's own 2>/dev/null.
  [ -r "$1" ] || { printf -v "$2" '%s' ""; return 1; }
  local _v
  _v=$(<"$1") || _v=""
  _v=${_v#"${_v%%[![:space:]]*}"}
  _v=${_v%"${_v##*[![:space:]]}"}
  printf -v "$2" '%s' "$_v"
}
# txt <path> [fallback] — file contents with a fallback when unreadable.
txt() { local v; readtrim "$1" v; if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "${2:-}"; fi; }
# num <path> [fallback] — first non-negative int token. Keeps the fallback
# (e.g. -1 for "not supported") only when the attribute is missing; a real
# value of zero (e.g. fan stopped at idle) stays 0.
num() {
  [ -r "$1" ] || { printf '%s' "${2:-}"; return; }
  local v; readtrim "$1" v
  v=${v%%[!0-9]*}
  while [ "${v#0}" != "$v" ]; do v=${v#0}; done
  [ -n "$v" ] && printf '%s' "$v" || printf '0'
}
# bool <path> [fallback] — msi-ec booleans are "on"/"off" (also accept 1/true).
bool() { case "$(txt "$1" "$2")" in 1|on|true|enabled) printf 1;; *) printf 0;; esac; }
# list — sysfs newline list (e.g. available_shift_modes) as a JSON string array.
list() {
  local out="" tok ls
  readtrim "$1" ls
  if [ -z "$ls" ]; then printf '[]'; return; fi
  while IFS= read -r tok; do
    [ -n "$tok" ] && out="$out\"${tok}\","
  done <<< "$ls"
  printf '[%s]' "${out%,}"
}
# avail <path> — 1 when the attribute exists, so the panel can tell
# "hardware doesn't expose this" from "turned off".
avail() { [ -r "$1" ] && printf 1 || printf 0; }

# fanrpm — fan1 tachometer, MControlCenter semantics (operate.cpp): the EC
# keeps a 2-byte big-endian tick counter at 0xCC/0xCD for this Gen-2 board
# (its detectFan1Address picks 0xCD when nonzero), and RPM = 480000/ticks.
# Ticks of 0 mean the fan is off or no tach; values that would produce an
# impossible RPM are treated as OFF. Emits "rpm has".
fanrpm() {
  [ -n "$ECIO" ] || { printf '"cpuFanRpm":0,"hasFanRpm":0'; return; }
  local hi lo ticks pair
  # One 2-byte read + one od (was: two dd, two od, one tr). Besides spawning
  # fewer processes this snapshots both tick bytes atomically — two separate
  # dd seeks could straddle a counter update and mix bytes from two moments.
  pair=$(dd if="$ECIO" bs=1 skip=204 count=2 2>/dev/null | od -An -tu1)
  read -r hi lo <<< "$pair"
  case "$hi" in ''|*[!0-9]*) hi=0;; esac
  case "$lo" in ''|*[!0-9]*) lo=0;; esac
  ticks=$(( (hi << 8) + lo ))
  if [ "$ticks" -gt 0 ] && [ $((480000 / ticks)) -le 15000 ]; then
    printf '"cpuFanRpm":%d,"hasFanRpm":1' $((480000 / ticks))
  else
    printf '"cpuFanRpm":0,"hasFanRpm":1'
  fi
}

# fancurve — MControlCenter-style curve tables (operate.cpp): fan1 temps
# 0x6A x6, speeds 0x72 x7; fan2 temps 0x82 x6, speeds 0x8A x7. Read-only;
# sanity-checked (speeds 0-100, temps 20-110) so EC revisions without MCC
# tables report hasFanCurve 0 and the panel hides the editor.
fancurve() {
  [ -n "$ECIO" ] || { printf '"hasFanCurve":0'; return; }
  local t1 s1 t2 s2 v
  t1=$(dd if="$ECIO" bs=1 skip=106 count=6 2>/dev/null | od -An -tu1)
  s1=$(dd if="$ECIO" bs=1 skip=114 count=7 2>/dev/null | od -An -tu1)
  t2=$(dd if="$ECIO" bs=1 skip=130 count=6 2>/dev/null | od -An -tu1)
  s2=$(dd if="$ECIO" bs=1 skip=138 count=7 2>/dev/null | od -An -tu1)
  for v in $s1 $s2; do
    case "$v" in ''|*[!0-9]*) printf '"hasFanCurve":0'; return;; esac
    [ "$v" -le 100 ] || { printf '"hasFanCurve":0'; return; }
  done
  for v in $t1 $t2; do
    case "$v" in ''|*[!0-9]*) printf '"hasFanCurve":0'; return;; esac
    [ "$v" -ge 20 ] && [ "$v" -le 110 ] || { printf '"hasFanCurve":0'; return; }
  done
  printf '"hasFanCurve":1,'
  printf '"fan1Temps":[%s],' "$(echo $t1 | tr ' ' ',')"
  printf '"fan1Speeds":[%s],' "$(echo $s1 | tr ' ' ',')"
  printf '"fan2Temps":[%s],' "$(echo $t2 | tr ' ' ',')"
  printf '"fan2Speeds":[%s]' "$(echo $s2 | tr ' ' ',')"
}

printf '{"present":1,'
printf '"acOnline":%s,' "$(num "$PSU/ADP1/online" 0)"
printf '"model":"%s",' "$(txt "$DMI/product_name" "")"
printf '"shiftModes":%s,' "$(list "$MEC/available_shift_modes")"
printf '"shiftMode":"%s",' "$(txt "$MEC/shift_mode" "")"
printf '"fanModes":%s,' "$(list "$MEC/available_fan_modes")"
printf '"fanMode":"%s",' "$(txt "$MEC/fan_mode" "")"
printf '"coolerBoost":%s,' "$(bool "$MEC/cooler_boost" "off")"
printf '"cpuTemp":%s,' "$(num "$MEC/cpu/realtime_temperature" -1)"
printf '"gpuTemp":%s,' "$(num "$MEC/gpu/realtime_temperature" -1)"
printf '"gpuFan":%s,' "$(num "$MEC/gpu/realtime_fan_speed" -1)"
printf '"hasCooler":%s,' "$(avail "$MEC/cooler_boost")"
printf '%s,' "$(fanrpm)"
printf '%s,' "$(fancurve)"
# hasFan2: dual-fan boards expose the GPU fan speed; single-fan boards
# (like this iGPU-only Modern 15 — CPU fan only, verified via tachometer
# + cooler-boost test) leave gpu/ empty. Presets then use fan1 tables only.
printf '"hasFan2":%s,' "$(avail "$MEC/gpu/realtime_fan_speed")"
printf '"isMsiEc":1}\n'