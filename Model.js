// Shared descriptions for the MSI Center summary widget.
//
// Everything here mirrors the msi-center desktop app: same labels, same
// EC tokens, same value ranges. If the app cannot do it, the widget does
// not show it.

const SHIFT_LABELS = {
  eco: "Super Battery",
  comfort: "Balanced",
  sport: "High Performance"
}

const SHIFT_CAPTIONS = {
  eco: "Maximises battery run time",
  comfort: "Balanced heat and noise",
  sport: "Maximum CPU and GPU power"
}

const FAN_LABELS = {
  auto: "Auto",
  silent: "Silent",
  advanced: "Advanced"
}

const FAN_CAPTIONS = {
  auto: "EC decides",
  silent: "Lowest noise",
  advanced: "Custom curve"
}

// The three charge limits the app offers. The EC accepts 50-100; these are
// the useful presets, not an arbitrary range.
const BATTERY_LIMITS = [
  { limit: 60, label: "60%", caption: "best longevity" },
  { limit: 80, label: "80%", caption: "balanced" },
  { limit: 100, label: "100%", caption: "full capacity" }
]

// Manual fan speed bounds, matching the desktop app and msi-fan-helper.
// Below 20% the EC would rather let the CPU throttle than spin the fan.
const FAN_MANUAL_MIN = 20
const FAN_MANUAL_MAX = 100

function name(map, value) {
  return map.hasOwnProperty(value) ? map[value] : String(value || "—")
}

function shiftModeName(mode) {
  return name(SHIFT_LABELS, mode)
}

function shiftModeCaption(mode) {
  return name(SHIFT_CAPTIONS, mode)
}

function fanModeName(mode) {
  return name(FAN_LABELS, mode)
}

function fanModeCaption(mode) {
  return name(FAN_CAPTIONS, mode)
}

function batteryLimits() {
  return BATTERY_LIMITS
}

function batteryLimitCaption(limit) {
  for (var i = 0; i < BATTERY_LIMITS.length; i++) {
    if (BATTERY_LIMITS[i].limit === limit) return BATTERY_LIMITS[i].caption
  }
  return ""
}

// Only show modes the EC actually reports, so the panel can never offer a
// mode this firmware rejects.
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
  return modes[(at + delta % modes.length + modes.length) % modes.length]
}

function defaultSnapshot() {
  return {
    present: false,
    model: "",
    ecFirmware: "",
    acOnline: false,
    shiftModes: [],
    shiftMode: "",
    fanModes: [],
    fanMode: "",
    coolerBoost: false,
    cpuTemp: -1,
    cpuMhz: -1,
    gpuMhz: -1,
    ramUsedKb: -1,
    ramTotalKb: -1,
    fanRpm: 0,
    hasFanRpm: false,
    fanLevel: -1,
    manualFan: -1,
    hasManualFan: false,
    battery: -1,
    batteryLimit: -1,
    kbdLevel: -1,
    kbdMax: 0,
    webcamBlocked: false,
    fnSwap: false,
    hasCooler: false,
    hasWebcam: false,
    hasFnSwap: false,
    hasKbd: false
  }
}

// One line of JSON from scripts/msi-read.sh. A line we cannot parse still
// proves the driver exists, so the widget stays visible rather than blinking.
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

function clampInt(value, min, max, fallback) {
  var v = parseInt(value, 10)
  if (isNaN(v)) return fallback
  return Math.max(min, Math.min(max, v))
}

// A setpoint for the manual-fan row: the active override when there is one,
// otherwise the speed the EC is applying right now, kept inside the bounds.
function fanSetpoint(snapshot) {
  var manual = parseInt(snapshot.manualFan, 10)
  if (isFinite(manual) && manual >= FAN_MANUAL_MIN) return Math.min(FAN_MANUAL_MAX, manual)
  var level = parseInt(snapshot.fanLevel, 10)
  if (!isFinite(level) || level < FAN_MANUAL_MIN) return Math.round((FAN_MANUAL_MIN + FAN_MANUAL_MAX) / 2)
  return Math.min(FAN_MANUAL_MAX, level)
}

function clampManualFan(value) {
  return clampInt(value, FAN_MANUAL_MIN, FAN_MANUAL_MAX, -1)
}

function manualFanRange() {
  return { min: FAN_MANUAL_MIN, max: FAN_MANUAL_MAX }
}

function elideError(str) {
  return String(str || "").replace(/\s+/g, " ").trim()
}

// "3.39 GHz" / "800 MHz"; em dash when the kernel exposes no clock.
function fmtClock(mhz) {
  var n = Number(mhz)
  if (!isFinite(n) || n < 0) return "—"
  return n >= 1000 ? (n / 1000).toFixed(2) + " GHz" : Math.round(n) + " MHz"
}

// "38% · 5.9 / 15.0 GB", matching the old standalone widget.
function fmtMemory(usedKb, totalKb) {
  var u = Number(usedKb)
  var t = Number(totalKb)
  if (!isFinite(u) || !isFinite(t) || u < 0 || t <= 0) return "—"
  var gb = 1048576
  return Math.round(u / t * 100) + "% · "
    + (u / gb).toFixed(1) + " / " + (t / gb).toFixed(1) + " GB"
}
