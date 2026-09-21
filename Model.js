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

const KBD_LABELS = {
  0: "Off",
  1: "Low",
  2: "Med",
  3: "High"
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

function kbdName(level) {
  return name(KBD_LABELS, level)
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
    firmware: "",
    shiftModes: [],
    shiftMode: "",
    fanModes: [],
    fanMode: "",
    coolerBoost: false,
    cpuTemp: -1,
    cpuFan: -1,
    cpuFanRpm: 0,
    hasFanRpm: false,
    cpuBasic: -1,
    gpuTemp: -1,
    gpuFan: -1,
    webcam: false,
    webcamBlock: false,
    fnKey: "",
    winKey: "",
    kbdLevel: 0,
    kbdMax: 3,
    hasShift: false,
    hasFan: false,
    hasCooler: false,
    hasWebcam: false,
    hasWebcamBlock: false,
    hasKbd: false,
    hasFanCurve: false,
    fan1Temps: [],
    fan1Speeds: [],
    fan2Temps: [],
    fan2Speeds: [],
    batteryStatus: "",
    batteryCapacity: -1,
    batteryStart: -1,
    batteryEnd: -1,
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

function validCurve(temps, speeds) {
  if (!Array.isArray(temps) || temps.length !== 6) return false
  if (!Array.isArray(speeds) || speeds.length !== 7) return false
  var prev = -1
  for (var i = 0; i < 6; i++) {
    var t = parseInt(temps[i], 10)
    if (isNaN(t) || t < 30 || t > 100 || t <= prev) return false
    prev = t
  }
  for (var j = 0; j < 7; j++) {
    var s = parseInt(speeds[j], 10)
    if (isNaN(s) || s < 0 || s > 100) return false
  }
  return true
}