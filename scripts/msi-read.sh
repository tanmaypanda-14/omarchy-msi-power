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
LED=/sys/class/leds/msiacpi::kbd_backlight
DMI=/sys/class/dmi/id
# Raw EC register file (ec_sys debugfs io, or the acpi_ec device). Used only
# for the USB power-share bit, which the msi-ec driver does not export. It is
# group-readable after setup/grant-msi-ec-access.sh; when it is not, the
# widget hides the toggle instead of guessing.
ECIO=""
for cand in /dev/ec /sys/kernel/debug/ec/ec0/io; do
  [ -r "$cand" ] && ECIO=$cand && break
done

if [ ! -d "$MEC" ]; then
  printf '{"present":0}\n'
  exit 0
fi

# trim <path> — strip surrounding whitespace, tolerate transient EC errors.
trim() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//' "$1" 2>/dev/null; }
# txt <path> [fallback] — file contents with a fallback when unreadable.
txt() { local v; v=$(trim "$1" 2>/dev/null); if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "${2:-}"; fi; }
# num <path> [fallback] — first non-negative int token. Keeps the fallback
# (e.g. -1 for "not supported") when the attribute is missing.
num() {
  [ -r "$1" ] || { printf '%s' "${2:-}"; return; }
  local v; v=$(trim "$1")
  v=${v%%[!0-9]*}
  v=$(printf '%s' "$v" | sed 's/^0*//')
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "${2:-}"
}
# bool <path> [fallback] — msi-ec booleans are "on"/"off" (also accept 1/true).
bool() { case "$(txt "$1" "$2")" in 1|on|true|enabled) printf 1;; *) printf 0;; esac; }
# list — sysfs newline list (e.g. available_shift_modes) as a JSON string array.
list() {
  local out="" tok ls
  ls=$(trim "$1" 2>/dev/null)
  if [ -z "$ls" ]; then printf '[]'; return; fi
  while IFS= read -r tok; do
    [ -n "$tok" ] && out="$out\"${tok}\","
  done <<< "$ls"
  printf '[%s]' "${out%,}"
}
# led path helpers — backlight lives under /sys/class/leds, not the EC.
lednum() { if [ -r "$LED/$1" ]; then num "$LED/$1" "${2:-}"; else printf '%s' "${2:-}"; fi; }
# avail <path> — 1 when the attribute exists, so the panel can tell
# "hardware doesn't expose this" from "turned off".
avail() { [ -r "$1" ] && printf 1 || printf 0; }

# ecbyte <offset> — raw EC byte as a decimal number, empty when unreadable.
# Tolerates a busy EC: the debugfs file can briefly return EINVAL.
ecbyte() {
  [ -n "$ECIO" ] || return 1
  dd if="$ECIO" bs=1 skip="$1" count=1 2>/dev/null | od -An -tu1 2>/dev/null | tr -d ' \n'
}
# usbpower — MControlCenter's USB power-share heuristic (operate.cpp): the
# byte 0xbf holds 0x08 "off" or 0x28 "on". Only those two states count; any
# other value means this EC uses 0xbf for something else, and we must not
# touch it. Emits "state has".
usbpower() {
  local b
  b=$(ecbyte 191)
  case "$b" in
    8)  printf '"usbPower":0,"hasUsbPower":1' ;;
    40) printf '"usbPower":1,"hasUsbPower":1' ;;
    *)  printf '"usbPower":0,"hasUsbPower":0' ;;
  esac
}

BAT=""
for b in "$PSU"/BAT*; do
  if [ -e "$b" ] && [ -r "$b/capacity" ]; then BAT=$b; break; fi
done

printf '{"present":1,'
printf '"acOnline":%s,' "$(num "$PSU/ADP1/online" 0)"
printf '"model":"%s",' "$(txt "$DMI/product_name" "")"
printf '"firmware":"%s",' "$(txt "$MEC/fw_version" "")"
printf '"shiftModes":%s,' "$(list "$MEC/available_shift_modes")"
printf '"shiftMode":"%s",' "$(txt "$MEC/shift_mode" "")"
printf '"fanModes":%s,' "$(list "$MEC/available_fan_modes")"
printf '"fanMode":"%s",' "$(txt "$MEC/fan_mode" "")"
printf '"coolerBoost":%s,' "$(bool "$MEC/cooler_boost" "off")"
printf '"cpuTemp":%s,' "$(num "$MEC/cpu/realtime_temperature" -1)"
printf '"cpuFan":%s,' "$(num "$MEC/cpu/realtime_fan_speed" -1)"
printf '"cpuBasic":%s,' "$(num "$MEC/cpu/basic_fan_speed" -1)"
printf '"gpuTemp":%s,' "$(num "$MEC/gpu/realtime_temperature" -1)"
printf '"gpuFan":%s,' "$(num "$MEC/gpu/realtime_fan_speed" -1)"
printf '"webcam":%s,' "$(bool "$MEC/webcam" "off")"
printf '"webcamBlock":%s,' "$(bool "$MEC/webcam_block" "off")"
printf '"fnKey":"%s",' "$(txt "$MEC/fn_key" "")"
printf '"winKey":"%s",' "$(txt "$MEC/win_key" "")"
printf '"kbdLevel":%s,' "$(lednum brightness 0)"
printf '"kbdMax":%s,' "$(lednum max_brightness 3)"
printf '"hasShift":%s,' "$(avail "$MEC/available_shift_modes")"
printf '"hasFan":%s,' "$(avail "$MEC/available_fan_modes")"
printf '"hasCooler":%s,' "$(avail "$MEC/cooler_boost")"
printf '"hasWebcam":%s,' "$(avail "$MEC/webcam")"
printf '"hasWebcamBlock":%s,' "$(avail "$MEC/webcam_block")"
printf '"hasKbd":%s,' "$(avail "$LED/brightness")"
printf '%s,' "$(usbpower)"
if [ -n "$BAT" ]; then
  printf '"batteryStatus":"%s",' "$(txt "$BAT/status" "")"
  printf '"batteryCapacity":%s,' "$(num "$BAT/capacity" -1)"
  printf '"batteryStart":%s,' "$(num "$BAT/charge_control_start_threshold" -1)"
  printf '"batteryEnd":%s,' "$(num "$BAT/charge_control_end_threshold" -1)"
else
  printf '"batteryStatus":"",'
  printf '"batteryCapacity":-1,'
  printf '"batteryStart":-1,'
  printf '"batteryEnd":-1,'
fi
printf '"isMsiEc":1}\n'