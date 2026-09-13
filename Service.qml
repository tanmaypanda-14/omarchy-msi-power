import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Owns the MSI EC state and every write. Reads are a plain sysfs snapshot
// (scripts/msi-read.sh) — free, world-readable, faithful to what the EC
// actually reports. Writes also go straight to sysfs (scripts/msi-set.sh):
// the MControlCenter helper the driver used to lean on is just a root
// write() wrapper, so this widget does the same thing in place, granted only
// by a udev group. The single exception is USB Power Share, which the driver
// does not export: it is one raw EC byte (0xbf) via the ec_sys debugfs file,
// also group-granted — no daemon involved either way.
Item {
  id: msi
  property var settings: ({})
  property string pluginDir: ""

  // Snapshot state, mirrored field-for-field from msi-read.sh.
  property bool present: false
  property bool acOnline: false
  property string model: ""
  property string firmware: ""
  property var shiftModes: []
  property string shiftMode: ""
  property var fanModes: []
  property string fanMode: ""
  property bool coolerBoost: false
  property int cpuTemp: -1
  property int cpuFan: -1
  property int cpuBasic: -1
  property int gpuTemp: -1
  property int gpuFan: -1
  property bool webcam: false
  property bool webcamBlock: false
  property string fnKey: ""
  property string winKey: ""
  property int kbdLevel: 0
  property int kbdMax: 3
  property bool usbPower: false
  property bool hasUsbPower: false
  property bool hasShift: false
  property bool hasFan: false
  property bool hasCooler: false
  property bool hasWebcam: false
  property bool hasWebcamBlock: false
  property bool hasKbd: false
  property string batteryStatus: ""
  property int batteryCapacity: -1
  property int batteryStart: -1
  property int batteryEnd: -1

  property bool busy: false
  property string actionStatus: ""
  property string lastError: ""
  property bool parseFailed: false

  readonly property bool hasBattery: batteryCapacity >= 0
  readonly property bool hasChargeLimit: batteryStart >= 0 && batteryEnd >= 0
  readonly property bool hasCpuSensor: cpuTemp >= 0
  readonly property bool hasGpuSensor: gpuTemp >= 0
  readonly property bool hasFnKey: fnKey !== ""
  readonly property bool hasWinKey: winKey !== ""
  // "Super Battery" is its own EC feature on some models; on machines that
  // have it the EC also lists `eco` as a shift mode, so the mode row covers
  // both. Nothing extra to surface here until the driver exports it.

  readonly property int refreshMs: {
    var n = parseInt(msi.setting("refreshMs", 2000), 10)
    return isNaN(n) ? 2000 : Math.max(500, Math.min(n, 15000))
  }
  readonly property bool autoPower: msi.setting("autoPower", false) === true

  readonly property string setScript: pluginDir !== ""
    ? pluginDir + "/scripts/msi-set.sh" : ""
  readonly property string readScript: pluginDir !== ""
    ? pluginDir + "/scripts/msi-read.sh" : ""

  property var _queued: null
  property string _lastAutoTarget: ""

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
    acOnline = snap.acOnline
    model = snap.model
    firmware = snap.firmware
    shiftModes = snap.shiftModes
    shiftMode = snap.shiftMode
    fanModes = snap.fanModes
    fanMode = snap.fanMode
    coolerBoost = snap.coolerBoost
    cpuTemp = snap.cpuTemp
    cpuFan = snap.cpuFan
    cpuBasic = snap.cpuBasic
    gpuTemp = snap.gpuTemp
    gpuFan = snap.gpuFan
    webcam = snap.webcam
    webcamBlock = snap.webcamBlock
    fnKey = snap.fnKey
    winKey = snap.winKey
    usbPower = !!snap.usbPower
    hasUsbPower = !!snap.hasUsbPower
    kbdLevel = Model.clampInt(snap.kbdLevel, 0, Math.max(1, snap.kbdMax), 0)
    kbdMax = Math.max(1, snap.kbdMax)
    hasShift = !!snap.hasShift
    hasFan = !!snap.hasFan
    hasCooler = !!snap.hasCooler
    hasWebcam = !!snap.hasWebcam
    hasWebcamBlock = !!snap.hasWebcamBlock
    hasKbd = !!snap.hasKbd
    batteryStatus = snap.batteryStatus
    batteryCapacity = Model.clampInt(snap.batteryCapacity, -1, 100, -1)
    batteryStart = Model.clampInt(snap.batteryStart, -1, 100, -1)
    batteryEnd = Model.clampInt(snap.batteryEnd, -1, 100, -1)

    if (!present) { present = true; return }
    followAutoPower(snap.shiftMode, snap.acOnline)
  }

  function followAutoPower(snapshotShiftMode, snapshotAcOnline) {
    if (!autoPower) { _lastAutoTarget = ""; return }
    var target = snapshotAcOnline ? "sport" : "eco"
    if (target === _lastAutoTarget && target !== snapshotShiftMode) {
      // A poll saw the requested mode already applied; settle the latch.
      _lastAutoTarget = ""
    }
    if (target !== snapshotShiftMode && target !== _lastAutoTarget) {
      _lastAutoTarget = target
      _write("shift", target)
    }
  }

  // Single write slot with last-verb-wins queuing, matching the keyboard
  // pattern of the rest of the shell.
  function _write(verb, value) {
    if (setScript === "" || verb === "") return
    if (writeProc.running) { _queued = { verb: verb, value: value }; return }
    busy = true
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
    if (autoPower) return
    _write("shift", mode)
  }

  function setFanMode(mode) {
    if (Model.supportedFanModes(msi).indexOf(mode) < 0) return
    _write("fan", mode)
  }

  function setCoolerBoost(enabled) {
    _write("cooler", enabled ? "on" : "off")
  }

  function setWebcam(enabled) {
    _write("webcam", enabled ? "on" : "off")
  }

  function setWebcamBlock(enabled) {
    _write("block", enabled ? "on" : "off")
  }

  function setFnKey(side) {
    if (side !== "left" && side !== "right") return
    _write("fnkey", side)
  }

  function setWinKey(side) {
    if (side !== "left" && side !== "right") return
    _write("winkey", side)
  }

  function setUsbPower(enabled) {
    _write("usb", enabled ? "on" : "off")
  }

  function setKbdLevel(level) {
    var v = Model.clampInt(level, 0, msi.kbdMax, msi.kbdLevel)
    if (v === msi.kbdLevel && parseInt(level, 10) !== msi.kbdLevel) return
    _write("kbd", v)
  }

  function setBatteryStart(pct) {
    var v = Model.clampInt(pct, 0, Math.max(0, msi.batteryEnd - 5), msi.batteryStart)
    if (v === msi.batteryStart && parseInt(pct, 10) !== msi.batteryStart) return
    _write("start", v)
  }

  function setBatteryEnd(pct) {
    var v = Model.clampInt(pct, msi.batteryStart + 5, 100, msi.batteryEnd)
    if (v === msi.batteryEnd && parseInt(pct, 10) !== msi.batteryEnd) return
    _write("end", v)
  }

  function cycleShift(delta) {
    if (autoPower) return
    var next = Model.nextShiftMode(msi, delta)
    if (next !== "") setShiftMode(next)
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
      msi.busy = false
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
    interval: 2400
    repeat: false
    onTriggered: msi.actionStatus = ""
  }
}