#!/bin/bash
# MCC-style fan-curve access for the tanmay.msi-power widget.
#
# MControlCenter drives "Advanced Fan Speed Control" with raw EC writes
# (src/operate.cpp): 7 speed points + 6 temp points per fan —
#   fan1 temps  0x6A..0x6F (6 bytes, °C)
#   fan1 speeds 0x72..0x78 (7 bytes, %)
#   fan2 temps  0x82..0x87 (6 bytes, °C)
#   fan2 speeds 0x8A..0x90 (7 bytes, %)
# plus fan_mode 0x8D (advanced) via sysfs (scripts/msi-set.sh fan advanced).
# Its root D-Bus helper (src/helper/helper.cpp:putValue) is just a
# range-checked (0-255) write() to the ec_sys raw interface loaded with
# write_support=1. This script is the same thing, narrowed to exactly those
# 26 curve bytes with strict validation, so the widget can offer MCC's
# Advanced tab without a daemon or blanket raw-EC access.
#
#   msi-fan-curve.sh read                        # JSON on stdout, read-only
#   sudo msi-fan-curve.sh apply fan1 54,58,62,66,77,93 0,50,60,65,75,75,100
#   sudo msi-fan-curve.sh apply fan2 50,60,70,82,90,93 45,50,65,72,80,85,100
#   sudo msi-fan-curve.sh apply both <t1> <s1> <t2> <s2>
#
# Reads work for the msi-ec group (io file is 0640). Writes need root
# (sudoers entry installed by setup/grant-msi-ec-access.sh allows the
# msi-ec group NOPASSWD for `apply` only, via /usr/local/bin copy) and
# ec_sys with write_support=1 (setup/ec-sys-write.conf).

set -u

FAN1_TEMP=106    # 0x6A
FAN1_SPEED=114   # 0x72
FAN2_TEMP=130    # 0x82
FAN2_SPEED=138   # 0x8A

find_io() {
  for cand in /sys/kernel/debug/ec/ec0/io /dev/ec; do
    [ -r "$cand" ] && printf '%s' "$cand" && return 0
  done
  return 1
}

# read_bytes <offset> <count> — space-separated decimal bytes on stdout.
read_bytes() {
  dd if="$ECIO" bs=1 skip="$1" count="$2" 2>/dev/null | od -An -tu1 | tr -s ' '
}

csv_to_list() {
  # echoes space-separated ints, fails on anything else
  local csv=$1 out="" tok
  [ -n "$csv" ] || return 1
  IFS=',' read -ra parts <<< "$csv"
  for tok in "${parts[@]}"; do
    [[ "$tok" =~ ^[0-9]+$ ]] || return 1
    out="$out $tok"
  done
  printf '%s' "$out"
}

as_json_array() {
  local out="" v
  for v in $1; do out="$out$v,"; done
  printf '[%s]' "${out%,}"
}

do_read() {
  ECIO=$(find_io) || { printf '{"hasFanCurve":0,"error":"no raw EC interface"}\n'; exit 1; }
  local t1 s1 t2 s2
  t1=$(read_bytes $FAN1_TEMP 6)
  s1=$(read_bytes $FAN1_SPEED 7)
  t2=$(read_bytes $FAN2_TEMP 6)
  s2=$(read_bytes $FAN2_SPEED 7)
  # Sanity: speeds must look like percents, temps like °C — otherwise this
  # EC revision doesn't keep MCC tables here and the UI hides the editor.
  local v ok=1
  for v in $s1 $s2; do
    if ! [[ "$v" =~ ^[0-9]+$ ]] || [ "$v" -gt 100 ]; then ok=0; break; fi
  done
  for v in $t1 $t2; do
    if ! [[ "$v" =~ ^[0-9]+$ ]] || [ "$v" -lt 20 ] || [ "$v" -gt 110 ]; then ok=0; break; fi
  done
  if [ "$ok" -eq 0 ]; then
    printf '{"hasFanCurve":0}\n'
    exit 0
  fi
  printf '{"hasFanCurve":1,"fan1Temps":%s,"fan1Speeds":%s,"fan2Temps":%s,"fan2Speeds":%s}\n' \
    "$(as_json_array "$t1")" "$(as_json_array "$s1")" \
    "$(as_json_array "$t2")" "$(as_json_array "$s2")"
}

# write_bytes <offset> <values...> — one dd per byte (MCC putValue semantics).
write_bytes() {
  local base=$1; shift
  local i=0 v
  for v in "$@"; do
    printf "$(printf '\\x%02x' "$v")" | dd of="$ECIO" bs=1 seek=$((base + i)) count=1 conv=notrunc status=none 2>/dev/null || return 1
    i=$((i + 1))
  done
}

# check_list <"v v ..."> <count> <min> <max> <label>
check_list() {
  local n=0 v
  for v in $1; do
    [[ "$v" =~ ^[0-9]+$ ]] || { echo "error: $5 '$v' is not a number" >&2; return 1; }
    [ "$v" -ge "$3" ] && [ "$v" -le "$4" ] || { echo "error: $5 '$v' out of range $3-$4" >&2; return 1; }
    n=$((n + 1))
  done
  [ "$n" -eq "$2" ] || { echo "error: $5 needs exactly $2 values, got $n" >&2; return 1; }
}

check_ascending() {
  local prev=-1 v
  for v in $1; do
    [ "$v" -gt "$prev" ] || { echo "error: $2 must strictly increase (got ... $prev $v ...)" >&2; return 1; }
    prev=$v
  done
}

apply_one() {
  # apply_one fan1|fan2 <temps_csv> <speeds_csv>
  local fan=$1 temps speeds base_t base_s
  if ! temps=$(csv_to_list "$2"); then echo "error: bad temps list '$2'" >&2; exit 2; fi
  if ! speeds=$(csv_to_list "$3"); then echo "error: bad speeds list '$3'" >&2; exit 2; fi
  check_list "$temps" 6 30 100 "temp" || exit 2
  check_list "$speeds" 7 0 100 "speed" || exit 2
  check_ascending "$temps" "temps" || exit 2
  case "$fan" in
    fan1) base_t=$FAN1_TEMP; base_s=$FAN1_SPEED ;;
    fan2) base_t=$FAN2_TEMP; base_s=$FAN2_SPEED ;;
    *) echo "error: fan must be fan1|fan2" >&2; exit 2 ;;
  esac
  # shellcheck disable=SC2086
  write_bytes "$base_t" $temps || { echo "error: temp write failed (need root + ec_sys write_support=1)" >&2; exit 1; }
  # shellcheck disable=SC2086
  write_bytes "$base_s" $speeds || { echo "error: speed write failed (need root + ec_sys write_support=1)" >&2; exit 1; }
}

cmd=${1:-read}
case "$cmd" in
  read)
    do_read
    ;;
  apply)
    if [ "$(id -u)" -ne 0 ]; then
      echo "error: fan-curve apply needs root (MControlCenter uses a root helper for the same writes)" >&2
      echo "  sudo $0 apply $2 ..." >&2
      exit 1
    fi
    ECIO=$(find_io) || { echo "error: no raw EC interface readable" >&2; exit 1; }
    if [ -r /sys/module/ec_sys/parameters/write_support ]; then
      ws=$(cat /sys/module/ec_sys/parameters/write_support 2>/dev/null)
      case "$ws" in Y|y|1) ;; *) echo "error: ec_sys loaded without write_support=1 — reload it (setup grants this)" >&2; exit 1 ;; esac
    fi
    target=${2:-}
    case "$target" in
      fan1|fan2)
        [ $# -eq 4 ] || { echo "usage: $0 apply fan1|fan2 <6 temps csv> <7 speeds csv>" >&2; exit 2; }
        apply_one "$target" "$3" "$4"
        ;;
      both)
        [ $# -eq 6 ] || { echo "usage: $0 apply both <t1csv> <s1csv> <t2csv> <s2csv>" >&2; exit 2; }
        apply_one fan1 "$3" "$4"
        apply_one fan2 "$5" "$6"
        ;;
      *)
        echo "usage: $0 read | apply fan1|fan2|both ..." >&2
        exit 2
        ;;
    esac
    echo "ok: curve written — set fan mode to advanced (msi-set.sh fan advanced) to activate, like MCC"
    ;;
  *)
    echo "usage: $0 read | apply fan1|fan2|both ..." >&2
    exit 2
    ;;
esac
