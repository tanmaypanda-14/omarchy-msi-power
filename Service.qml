import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Owns the MSI EC state and every write, mirroring the msi-center app.
//
// Reads are a plain sysfs snapshot (scripts/msi-read.sh). Writes are the same
// sysfs writes the app performs (scripts/msi-set.sh): shift_mode, fan_mode,
// cooler_boost and the battery charge limit. No raw EC writes and no root
// helper are involved — the udev rule grants the msi-ec group write access to
// exactly those attributes.
Item {
  id: msi
  property var settings: ({})
  property string pluginDir: ""

  // Snapshot state, mirrored field-for-field from msi-read.sh / Model.js.
  property bool present: false
  property string model: ""
  property string ecFirmware: ""
  property bool acOnline: false
  property var shiftModes: []
  property string shiftMode: ""
  property var fanModes: []
  property string fanMode: ""
  property bool coolerBoost: false
  property int cpuTemp: -1
  property int cpuMhz: -1
  property int gpuMhz: -1
  property int ramUsedKb: -1
  property int ramTotalKb: -1
  property int fanRpm: 0
  property bool hasFanRpm: false
  property int fanLevel: -1
  property int battery: -1
  property int batteryLimit: -1
  property int kbdLevel: -1
  property int kbdMax: 0
  property bool webcamBlocked: false
  property bool fnSwap: false
  property bool hasCooler: false
  property bool hasWebcam: false
  property bool hasFnSwap: false
  property bool hasKbd: false

  property string actionStatus: ""
  property string lastError: ""
  property bool parseFailed: false

  readonly property bool hasCpuSensor: cpuTemp >= 0
  readonly property bool hasCpuClock: cpuMhz >= 0
  readonly property bool hasGpuClock: gpuMhz >= 0
  readonly property bool hasRam: ramTotalKb > 0
  readonly property bool hasBattery: battery >= 0

  readonly property int refreshMs: {
    var n = parseInt(msi.setting("refreshMs", 2000), 10)
    return isNaN(n) ? 2000 : Math.max(500, Math.min(n, 15000))
  }

  readonly property string setScript: pluginDir !== ""
    ? pluginDir + "/scripts/msi-set.sh" : ""
  readonly property string readScript: pluginDir !== ""
    ? pluginDir + "/scripts/msi-read.sh" : ""

  property var _queued: null

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // Force a fresh snapshot now (called on panel open and after every write).
  function refresh() {
    if (readScript === "" || readProc.running) return
    readProc.command = [readScript]
    readProc.running = true
  }

  function applySnapshot(raw) {
    var snap = Model.parseSnapshot(raw)
    if (!snap.ok) {
      lastError = Model.elideError(snap.parseError || "msi-read.sh returned unparsable output")
      parseFailed = true
      return
    }
    parseFailed = false
    lastError = ""
    present = snap.present
    model = snap.model
    ecFirmware = snap.ecFirmware
    acOnline = snap.acOnline
    shiftModes = snap.shiftModes
    shiftMode = snap.shiftMode
    fanModes = snap.fanModes
    fanMode = snap.fanMode
    coolerBoost = snap.coolerBoost
    cpuTemp = Model.clampInt(snap.cpuTemp, -1, 120, -1)
    cpuMhz = Model.clampInt(snap.cpuMhz, -1, 20000, -1)
    gpuMhz = Model.clampInt(snap.gpuMhz, -1, 20000, -1)
    ramUsedKb = Model.clampInt(snap.ramUsedKb, -1, 1073741824, -1)
    ramTotalKb = Model.clampInt(snap.ramTotalKb, -1, 1073741824, -1)
    fanRpm = Model.clampInt(snap.fanRpm, 0, 15000, 0)
    hasFanRpm = !!snap.hasFanRpm
    fanLevel = Model.clampInt(snap.fanLevel, -1, 100, -1)
    battery = Model.clampInt(snap.battery, -1, 100, -1)
    batteryLimit = Model.clampInt(snap.batteryLimit, -1, 100, -1)
    kbdLevel = Model.clampInt(snap.kbdLevel, -1, 255, -1)
    kbdMax = Model.clampInt(snap.kbdMax, 0, 255, 0)
    webcamBlocked = !!snap.webcamBlocked
    fnSwap = !!snap.fnSwap
    hasCooler = !!snap.hasCooler
    hasWebcam = !!snap.hasWebcam
    hasFnSwap = !!snap.hasFnSwap
    hasKbd = !!snap.hasKbd
  }

  // Single write slot with last-verb-wins queuing.
  function _write(verb, value) {
    if (setScript === "" || verb === "") return
    if (writeProc.running) { _queued = { verb: verb, value: value }; return }
    writeProc.command = [setScript, verb, String(value)]
    writeProc.running = true
  }

  function _maybeNext() {
    if (_queued) {
      var q = _queued
      _queued = null
      _write(q.verb, q.value)
      return
    }
    refresh()
  }

  function setShiftMode(mode) {
    if (Model.supportedShiftModes(msi).indexOf(mode) < 0) return
    _write("shift", mode)
  }

  function setFanMode(mode) {
    if (Model.supportedFanModes(msi).indexOf(mode) < 0) return
    _write("fan", mode)
  }

  function cycleShift(delta) {
    var next = Model.nextShiftMode(msi, delta)
    if (next !== "") setShiftMode(next)
  }

  function setCoolerBoost(enabled) {
    _write("cooler", enabled ? "on" : "off")
  }

  function setBatteryLimit(limit) {
    var allowed = [60, 80, 100]
    if (allowed.indexOf(limit) < 0) return
    _write("battery", limit)
  }

  Timer {
    interval: msi.refreshMs
    running: msi.pluginDir !== ""
    repeat: true
    triggeredOnStart: true
    onTriggered: msi.refresh()
  }

  Process {
    id: readProc
    stdout: StdioCollector { id: readOut; waitForEnd: true }
    stderr: StdioCollector { id: readErr; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        msi.lastError = Model.elideError(readErr.text || "msi-read.sh failed")
        msi.parseFailed = true
        return
      }
      msi.applySnapshot(readOut.text)
    }
  }

  Process {
    id: writeProc
    stderr: StdioCollector { id: writeErr; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        msi.actionStatus = Model.elideError(writeErr.text || "The EC rejected the change")
        actionStatusTimer.restart()
        msi._queued = null
      }
      msi._maybeNext()
    }
  }

  Timer {
    id: actionStatusTimer
    interval: 2800
    repeat: false
    onTriggered: msi.actionStatus = ""
  }
}
