// Shared state descriptions for the MSI power widget.

// Shift modes are the EC's own tokens; the labels mirror MControlCenter's
// user-scenario names so the widget reads the same way the app does.
const SHIFT_LABELS = {
  eco: "Super Battery",
  comfort: "Balanced",
  sport: "High Performance"
}

const FAN_LABELS = {
  auto: "Auto",
  silent: "Silent",
  advanced: "Advanced"
}

function name(map, value) {
  return map.hasOwnProperty(value) ? map[value] : String(value || "—")
}

function shiftModeName(mode) {
  return name(SHIFT_LABELS, mode)
}

function fanModeName(mode) {
  return name(FAN_LABELS, mode)
}

// Modes the EC actually reports, in EC order, so the panel never shows a
// mode this firmware cannot enter.
function supportedShiftModes(snapshot) {
  var list = Array.isArray(snapshot.shiftModes) ? snapshot.shiftModes : []
  return list.filter(function (m) { return SHIFT_LABELS.hasOwnProperty(m) })
}

function supportedFanModes(snapshot) {
  var list = Array.isArray(snapshot.fanModes) ? snapshot.fanModes : []
  return list.filter(function (m) { return FAN_LABELS.hasOwnProperty(m) })
}

function nextShiftMode(snapshot, delta) {
  var modes = supportedShiftModes(snapshot)
  if (modes.length === 0) return ""
  var at = modes.indexOf(snapshot.shiftMode)
  if (at < 0) at = 0
  var next = (at + delta % modes.length + modes.length) % modes.length
  return modes[next]
}

function defaultSnapshot() {
  return {
    present: false,
    acOnline: false,
    model: "",
    shiftModes: [],
    shiftMode: "",
    fanModes: [],
    fanMode: "",
    coolerBoost: false,
    cpuTemp: -1,
    cpuFanRpm: 0,
    hasFanRpm: false,
    gpuTemp: -1,
    gpuFan: -1,
    hasCooler: false,
    hasFanCurve: false,
    hasFan2: false,
    fan1Temps: [],
    fan1Speeds: [],
    fan2Temps: [],
    fan2Speeds: [],
    isMsiEc: false
  }
}

// The snapshot is a single line of JSON from scripts/msi-read.sh. A line we
// cannot parse still proves the msi-ec driver exists, so present stays true
// and the widget stays visible rather than blinking out.
function parseSnapshot(raw) {
  var next = defaultSnapshot()
  try {
    var o = JSON.parse(String(raw || ""))
    for (var k in o) if (o.hasOwnProperty(k)) next[k] = o[k]
  } catch (e) {
    next.ok = false
    next.parseError = String(e.message || e)
  }
  next.present = !!next.present
  next.ok = next.ok !== false
  return next
}

function elideError(str) {
  return String(str || "").replace(/\s+/g, " ").trim()
}

// Percentages clamp for a possible mismatch between what the EC allows and
// what the panel asked for: the EC re-read after each write is the truth.
function clampInt(value, min, max, fallback) {
  var v = parseInt(value, 10)
  if (isNaN(v)) return fallback
  return Math.max(min, Math.min(max, v))
}

// Fan-curve helpers (MControlCenter Advanced tab: 6 temps + 7 speeds / fan).
function clampCurve(list, count, min, max, fallback) {
  var src = Array.isArray(list) ? list : []
  var out = []
  for (var i = 0; i < count; i++) {
    var v = parseInt(src[i], 10)
    out.push(isNaN(v) ? fallback : Math.max(min, Math.min(max, v)))
  }
  return out
}

// One-tap manual fan presets: fixed speed tables (MCC Advanced layout, both
// fans). Temps are left as the EC has them; only speeds are preset. Speeds
// never drop below 25% (no fan-off point) and the last point stays 100% so
// the EC still maxes out at critical temperature.
const FAN_PRESETS = {
  quiet: {
    label: "Quiet",
    caption: "Low fixed speeds",
    fan1Speeds: [25, 25, 35, 45, 55, 65, 100],
    fan2Speeds: [25, 35, 45, 55, 65, 75, 100]
  },
  balanced: {
    label: "Balanced",
    caption: "Stock speeds",
    fan1Speeds: [25, 50, 60, 65, 75, 75, 100],
    fan2Speeds: [45, 50, 65, 72, 80, 85, 100]
  },
  performance: {
    label: "Performance",
    caption: "High fixed speeds",
    fan1Speeds: [30, 55, 70, 85, 100, 100, 100],
    fan2Speeds: [50, 65, 80, 90, 100, 100, 100]
  }
}

function fanPresetNames() {
  return ["quiet", "balanced", "performance"]
}

function fanPreset(name) {
  return FAN_PRESETS.hasOwnProperty(name) ? FAN_PRESETS[name] : null
}

function fanPresetLabel(name) {
  var p = fanPreset(name)
  return p ? p.label : String(name || "—")
}

function fanPresetCaption(name) {
  var p = fanPreset(name)
  return p ? p.caption : ""
}

function sameSpeeds(a, b) {
  if (!Array.isArray(a) || !Array.isArray(b) || a.length !== 7 || b.length !== 7) return false
  for (var i = 0; i < 7; i++) {
    if (parseInt(a[i], 10) !== parseInt(b[i], 10)) return false
  }
  return true
}

// Which preset is currently on the EC (speeds match, advanced mode on).
// Anything else in advanced mode is reported as custom (""). Single-fan
// boards (no GPU fan speed) match on the CPU/fan1 table only.
function matchingPreset(snapshot) {
  if (!snapshot || snapshot.fanMode !== "advanced" || !snapshot.hasFanCurve) return ""
  var names = fanPresetNames()
  for (var i = 0; i < names.length; i++) {
    var p = fanPreset(names[i])
    if (!sameSpeeds(snapshot.fan1Speeds, p.fan1Speeds)) continue
    if (snapshot.hasFan2 && !sameSpeeds(snapshot.fan2Speeds, p.fan2Speeds)) continue
    return names[i]
  }
  return ""
}