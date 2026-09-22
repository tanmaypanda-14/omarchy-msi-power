import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Owns the MSI EC state and every write. Reads are a plain sysfs snapshot
// (scripts/msi-read.sh) — free, world-readable, faithful to what the EC
// actually reports. Writes also go straight to sysfs (scripts/msi-set.sh):
// the MControlCenter helper the driver used to lean on is just a root
// write() wrapper, so this widget does the same thing in place, granted only
// by a udev group — no daemon, no extra privileges.
Item {
  id: msi
  property var settings: ({})
  property string pluginDir: ""

  // Snapshot state, mirrored field-for-field from msi-read.sh.
  property bool present: false
  property bool acOnline: false
  property string model: ""
  property var shiftModes: []
  property string shiftMode: ""
  property var fanModes: []
  property string fanMode: ""
  property bool coolerBoost: false
  property int cpuTemp: -1
  property int cpuFanRpm: 0
  property bool hasFanRpm: false
  property int gpuTemp: -1
  property int gpuFan: -1
  property bool hasCooler: false
  // MCC-style fan curves (Advanced tab): 6 temps + 7 speeds per fan.
  property bool hasFanCurve: false
  property bool hasFan2: false
  property var fan1Temps: []
  property var fan1Speeds: []
  property var fan2Temps: []
  property var fan2Speeds: []
  property string curveStatus: ""

  // Last applied preset, restored on startup (MCC loadSettings parity —
  // the EC drops mode + tables on cold boot).
  property string savedPreset: ""
  property string _pendingPreset: ""
  property bool _restoreDone: false
  property bool _stateLoaded: false

  property string actionStatus: ""
  property string lastError: ""
  property bool parseFailed: false

  readonly property bool hasCpuSensor: cpuTemp >= 0
  readonly property bool hasGpuSensor: gpuTemp >= 0
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
  // Curve writer: root-owned copy installed by setup (sudoers scoped to
  // `apply` only).
  readonly property string curveSysPath: "/usr/local/bin/omarchy-msi-fan-curve"
  readonly property string stateScript: pluginDir !== ""
    ? pluginDir + "/scripts/msi-preset-state.sh" : ""

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
    shiftModes = snap.shiftModes
    shiftMode = snap.shiftMode
    fanModes = snap.fanModes
    fanMode = snap.fanMode
    coolerBoost = snap.coolerBoost
    cpuTemp = snap.cpuTemp
    cpuFanRpm = Model.clampInt(snap.cpuFanRpm, 0, 15000, 0)
    hasFanRpm = !!snap.hasFanRpm
    gpuTemp = snap.gpuTemp
    gpuFan = snap.gpuFan
    hasCooler = !!snap.hasCooler
    hasFanCurve = !!snap.hasFanCurve
    hasFan2 = !!snap.hasFan2
    fan1Temps = Model.clampCurve(snap.fan1Temps, 6, 30, 100, 60)
    fan1Speeds = Model.clampCurve(snap.fan1Speeds, 7, 0, 100, 50)
    fan2Temps = Model.clampCurve(snap.fan2Temps, 6, 30, 100, 60)
    fan2Speeds = Model.clampCurve(snap.fan2Speeds, 7, 0, 100, 50)

    if (!present) { present = true; return }
    followAutoPower(snap.shiftMode, snap.acOnline)
    maybeRestore()
  }

  // One-shot restore of the last preset after (re)start: if the EC already
  // matches, there is nothing to do; otherwise re-apply it. Runs off the
  // regular poll snapshots, so it also waits out driver load at login.
  function maybeRestore() {
    if (_restoreDone || !_stateLoaded) return
    if (savedPreset === "") { _restoreDone = true; return }
    if (!hasFanCurve) return
    if (Model.matchingPreset(msi) === savedPreset) { _restoreDone = true; return }
    _restoreDone = true
    applyFanPreset(savedPreset)
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

  // One-tap manual fan preset: write the preset speeds (keeping the EC's
  // current temps) through the validated root-scoped curve script (raw EC,
  // like MCC's root helper), flip the EC to advanced so the table is live,
  // then re-read the EC so the panel shows what actually landed.
  function applyFanPreset(name) {
    var preset = Model.fanPreset(name)
    if (!preset) return
    if (!hasFanCurve) {
      curveStatus = "No fan tables on this EC"
      curveStatusTimer.restart()
      return
    }
    if (curveProc.running) return
    _pendingPreset = name
    var t1 = fan1Temps.map(function (v) { return parseInt(v, 10) }).join(",")
    var s1 = preset.fan1Speeds.join(",")
    // Single-fan boards only use the CPU/fan1 table; dual-fan writes both.
    if (hasFan2) {
      var t2 = fan2Temps.map(function (v) { return parseInt(v, 10) }).join(",")
      var s2 = preset.fan2Speeds.join(",")
      // Prefer the root-owned copy (sudoers NOPASSWD for `apply` only).
      curveProc.command = ["sudo", "-n", curveSysPath, "apply", "both", t1, s1, t2, s2]
    } else {
      curveProc.command = ["sudo", "-n", curveSysPath, "apply", "fan1", t1, s1]
    }
    curveProc.running = true
    _write("fan", "advanced")
  }

  function setCoolerBoost(enabled) {
    _write("cooler", enabled ? "on" : "off")
  }

  function cycleShift(delta) {
    if (autoPower) return
    var next = Model.nextShiftMode(msi, delta)
    if (next !== "") setShiftMode(next)
  }

  Component.onCompleted: {
    if (stateScript !== "") {
      stateProc.command = [stateScript, "get"]
      stateProc.running = true
    } else {
      _restoreDone = true
    }
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

  // Privileged MCC-style curve writer (sudo -n: fails fast without a tty;
  // the grant installs the NOPASSWD rule so the widget never prompts).
  Process {
    id: curveProc
    stderr: StdioCollector { id: curveErr; waitForEnd: true }
    stdout: StdioCollector { id: curveOut; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        var detail = Model.elideError(curveErr.text || "")
        if (detail.indexOf("no password was provided") >= 0 || detail.indexOf("a password is required") >= 0)
          msi.curveStatus = "Curve writes need the sudo grant — re-run setup/install.sh (sudo)"
        else if (detail !== "")
          msi.curveStatus = detail
        else
          msi.curveStatus = "Curve write failed"
        curveStatusTimer.restart()
      } else {
        msi.curveStatus = ""
        // Remember the choice so the next login restores it (cold boot
        // wipes the EC tables). Runs as the user, no privileges needed.
        if (msi._pendingPreset !== "" && msi.stateScript !== "") {
          stateSaveProc.command = [msi.stateScript, "set", msi._pendingPreset]
          stateSaveProc.running = true
        }
      }
      msi._pendingPreset = ""
      msi.refresh()
    }
  }

  // Saved-preset load (startup) and save (after each successful apply).
  Process {
    id: stateProc
    stdout: StdioCollector { id: stateOut; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode === 0) msi.savedPreset = Model.elideError(stateOut.text || "")
      msi._stateLoaded = true
      msi.maybeRestore()
    }
  }

  Process {
    id: stateSaveProc
  }

  Timer {
    id: curveStatusTimer
    interval: 4000
    repeat: false
    onTriggered: msi.curveStatus = ""
  }

  Timer {
    id: actionStatusTimer
    interval: 2400
    repeat: false
    onTriggered: msi.actionStatus = ""
  }
}