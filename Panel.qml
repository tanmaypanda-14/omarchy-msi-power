import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// MSI Power + system monitor: one bar pill. The EC snapshot (power modes,
// fan, cooler boost, EC sensors) comes from the msi service; live system
// stats (CPU usage, RAM, storage) are sampled by bin/omarchy-msi-stats.
// Sensors are laid out as plain label/value rows, matching the network panel.
Panel {
  id: root
  moduleName: "tanmay.msi-power"
  ipcTarget: "tanmay.msi-power"
  manageIpc: false

  // Bar-widget roots receive no manifest from the host, and Omarchy always
  // keeps user plugins at ~/.config/omarchy/plugins/<id>.
  readonly property string pluginDir: {
    var home = Quickshell.env("HOME") || ""
    return home !== "" ? home + "/.config/omarchy/plugins/tanmay.msi-power" : ""
  }
  readonly property string statsScript: String(Qt.resolvedUrl("bin/omarchy-msi-stats")).replace("file://", "")

  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property bool hideWhenUnsupported: setting("hideWhenUnsupported", true) === true
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color warn: Qt.lighter(urgent, 1.35)
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color barIconColor: !msi.present
    ? Qt.darker(barForeground, 1.55)
    : ((msi.coolerBoost || root.tempHot) ? urgent : barForeground)
  readonly property int tempAlertAt: Number(setting("tempAlertAt", 80)) || 80
  readonly property bool tempHot: (msi.hasCpuSensor && msi.cpuTemp >= tempAlertAt)
    || (msi.hasGpuSensor && msi.gpuTemp >= tempAlertAt)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var shiftModes: Model.supportedShiftModes(msi)
  readonly property var fanModes: Model.supportedFanModes(msi)

  // --------------------------------------------------------------- system
  property var stats: ({})
  readonly property bool hasData: stats && stats.cpu !== undefined
  readonly property var cpuStat: hasData ? stats.cpu : null
  readonly property var memStat: hasData ? stats.mem : null
  readonly property var disksStat: hasData ? stats.disks || [] : []

  // Every focusable row in order, so j/k never land on a hidden control.
  // With fan tables on the EC the fan list is the 3 manual presets plus
  // Advanced; without them it is the raw EC fan modes.
  readonly property var cursorRows: {
    var rows = []
    for (var i = 0; i < shiftModes.length; i++) rows.push("shift:" + shiftModes[i])
    if (msi.hasFanCurve) {
      var presets = Model.fanPresetNames()
      for (var p = 0; p < presets.length; p++) rows.push("preset:" + presets[p])
      if (fanModes.indexOf("advanced") >= 0) rows.push("fan:advanced")
    } else {
      for (var j = 0; j < fanModes.length; j++) rows.push("fan:" + fanModes[j])
    }
    if (msi.hasCooler) rows.push("cooler")
    return rows
  }

  readonly property string cursorRow: cursorRows.length === 0
    ? ""
    : cursorRows[Math.max(0, Math.min(cursorIndex, cursorRows.length - 1))]

  function rowHasCursor(name) {
    return cursorActive && cursorRow === name
  }

  function moveCursor(dy) {
    cursorActive = true
    if (cursorRows.length === 0) return
    cursorIndex = Math.max(0, Math.min(cursorRows.length - 1, cursorIndex + dy))
  }

  function focusRow(name) {
    var at = cursorRows.indexOf(name)
    if (at < 0) return
    cursorActive = true
    cursorIndex = at
  }

  function activateCursor() {
    var name = cursorRow
    if (name.indexOf("shift:") === 0) msi.setShiftMode(name.substring(6))
    else if (name.indexOf("preset:") === 0) msi.applyFanPreset(name.substring(7))
    else if (name.indexOf("fan:") === 0) msi.setFanMode(name.substring(4))
    else if (name === "cooler") msi.setCoolerBoost(!msi.coolerBoost)
  }

  function fmtPercent(p) {
    return (p === null || p === undefined || isNaN(Number(p))) ? "—" : Math.round(Number(p)) + "%"
  }

  function fmtBytes(b) {
    var n = Number(b || 0)
    if (n >= 1073741824) return (n / 1073741824).toFixed(1) + " GiB"
    if (n >= 1048576) return (n / 1048576).toFixed(0) + " MiB"
    if (n >= 1024) return (n / 1024).toFixed(0) + " KiB"
    return Math.round(n) + " B"
  }

  function tempColor(t, warnAt, critAt) {
    if (t === null || t === undefined) return root.foreground
    var n = Number(t)
    if (n >= critAt) return root.urgent
    if (n >= warnAt) return root.warn
    return root.foreground
  }

  function refreshStats() {
    if (!statsProc.running) statsProc.running = true
  }

  visible: msi.present || !hideWhenUnsupported
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursorIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    msi.refresh()
    refreshStats()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: msi
    settings: root.settings
    pluginDir: root.pluginDir
  }

  Timer {
    interval: 2500
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshStats()
  }

  Process {
    id: statsProc
    command: [root.statsScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text || ""))
          if (parsed && typeof parsed === "object") root.stats = parsed
        } catch (e) { /* keep last good snapshot */ }
      }
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { msi.refresh(); root.refreshStats(); return "ok" }
    function cycleShift(): string { msi.cycleShift(1); return "ok" }
    function status(): string {
      return msi.present
        ? Model.shiftModeName(msi.shiftMode) + " · " + root.fanDisplay()
        : "msi-ec not loaded"
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    foreground: root.barIconColor
    tooltipText: "MSI Power Control"
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) msi.cycleShift(1)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) {
        var key = String(t).toLowerCase()
        if (key === "r") { msi.refresh(); root.refreshStats() }
        else if (key === "m") msi.cycleShift(1)
        else if (key === "f") root.cycleFan()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: msi.model !== "" ? msi.model : "MSI Laptop"
            detail: msi.shiftMode !== "" ? Model.shiftModeName(msi.shiftMode) : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: msi.present ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: ""
                color: msi.coolerBoost ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: msi.actionStatus !== "" || (msi.parseFailed && msi.lastError !== "")
            width: parent.width
            text: msi.actionStatus !== "" ? msi.actionStatus : msi.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: !msi.present
            width: parent.width
            text: "The msi-ec kernel module is not loaded — install it or reboot after loading to control this laptop's embedded controller."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          // -------------------------------------------------------- SENSORS
          Column {
            visible: msi.hasCpuSensor || msi.hasGpuSensor || root.hasData
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "SENSORS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              width: parent.width
              spacing: Style.spacing.labelGap

              StatRow {
                label: "CPU"
                value: root.fmtPercent(root.cpuStat ? root.cpuStat.percent : null)
                valueColor: root.cpuStat && root.cpuStat.percent >= 85 ? root.urgent : root.foreground
              }

              StatRow {
                visible: msi.hasCpuSensor
                label: "CPU temp"
                value: msi.cpuTemp >= 0 ? msi.cpuTemp + "°C" : "—"
                valueColor: root.tempColor(msi.hasCpuSensor ? msi.cpuTemp : null, 75, 85)
              }

              StatRow {
                visible: msi.hasFanRpm
                label: "CPU fan"
                value: msi.cpuFanRpm > 0 ? msi.cpuFanRpm + " rpm" : "OFF"
                valueColor: msi.hasCooler && msi.cpuFanRpm >= 7000 ? Color.accent : root.foreground
              }

              StatRow {
                visible: msi.hasGpuSensor
                label: "GPU"
                value: msi.gpuTemp >= 0 ? msi.gpuTemp + "°C" + (msi.gpuFan >= 0 ? " · " + msi.gpuFan + "%" : "") : "—"
                valueColor: root.tempColor(msi.hasGpuSensor ? msi.gpuTemp : null, 80, 88)
              }
            }

            PanelSeparator {
              visible: root.hasData
              foreground: root.foreground
            }

            Column {
              visible: root.hasData
              width: parent.width
              spacing: Style.spacing.labelGap

              StatRow {
                label: "Memory"
                value: root.memStat
                  ? root.fmtBytes(root.memStat.usedBytes) + " / " + root.fmtBytes(root.memStat.totalBytes)
                    + " · " + root.fmtPercent(root.memStat.percent)
                  : "—"
              }

              StatRow {
                visible: root.memStat && root.memStat.swapTotalBytes > 0
                label: "Swap"
                value: root.memStat
                  ? root.fmtBytes(root.memStat.swapUsedBytes) + " / " + root.fmtBytes(root.memStat.swapTotalBytes)
                    + " · " + root.fmtPercent(root.memStat.swapPercent)
                  : "—"
              }
            }

            PanelSeparator {
              visible: root.disksStat.length > 0
              foreground: root.foreground
            }

            Column {
              visible: root.disksStat.length > 0
              width: parent.width
              spacing: Style.spacing.labelGap

              PanelSectionHeader {
                text: "STORAGE"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: root.disksStat

                StatRow {
                  required property var modelData
                  label: modelData.device
                  value: root.fmtBytes(modelData.usedBytes) + " / " + root.fmtBytes(modelData.totalBytes)
                    + " · " + root.fmtPercent(modelData.percent)
                    + (modelData.tempC !== null && modelData.tempC !== undefined
                       ? " · " + Math.round(modelData.tempC) + "°C" : "")
                  valueColor: root.tempColor(modelData.tempC, 48, 58)
                }
              }
            }
          }

          PanelSeparator {
            visible: (msi.hasCpuSensor || msi.hasGpuSensor || root.hasData) && shiftModes.length > 0
            foreground: root.foreground
          }

          // ------------------------------------------------------ POWER MODE
          Column {
            visible: shiftModes.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "POWER MODE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: shiftModes
                ModeRow {
                  required property var modelData
                  width: parent.width
                  rowName: "shift:" + modelData
                  text: Model.shiftModeName(modelData)
                  caption: modeCaption(modelData)
                  selected: msi.shiftMode === modelData
                  onClicked: msi.setShiftMode(modelData)
                }
              }
            }
          }

          PanelSeparator {
            visible: shiftModes.length > 0 && (fanModes.length > 0 || msi.hasCooler)
            foreground: root.foreground
          }

          // ----------------------------------------------------------- FAN
          // With fan tables on the EC: 3 one-tap manual presets (fixed
          // speeds via the MCC Advanced tables) + Advanced for the current
          // EC curve. Without tables: the raw EC fan modes.
          Column {
            visible: fanModes.length > 0 || msi.hasCooler
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "FAN"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              visible: msi.curveStatus !== ""
              width: parent.width
              text: msi.curveStatus
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Column {
              visible: !msi.hasFanCurve && fanModes.length > 0
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: fanModes
                ModeRow {
                  required property var modelData
                  width: parent.width
                  rowName: "fan:" + modelData
                  text: Model.fanModeName(modelData)
                  caption: ""
                  selected: msi.fanMode === modelData
                  onClicked: msi.setFanMode(modelData)
                }
              }
            }

            Column {
              visible: msi.hasFanCurve
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: Model.fanPresetNames()
                ModeRow {
                  required property var modelData
                  width: parent.width
                  rowName: "preset:" + modelData
                  text: Model.fanPresetLabel(modelData)
                  caption: Model.fanPresetCaption(modelData)
                  selected: Model.matchingPreset(msi) === modelData
                  onClicked: msi.applyFanPreset(modelData)
                }
              }

              ModeRow {
                visible: fanModes.indexOf("advanced") >= 0
                width: parent.width
                rowName: "fan:advanced"
                text: Model.fanModeName("advanced")
                caption: "Current EC curve"
                selected: msi.fanMode === "advanced" && Model.matchingPreset(msi) === ""
                onClicked: msi.setFanMode("advanced")
              }
            }

            ToggleRow {
              visible: msi.hasCooler
              width: parent.width
              rowName: "cooler"
              label: "Cooler Boost"
              caption: "Max out all fans"
              checked: msi.coolerBoost
              onToggled: msi.setCoolerBoost(!msi.coolerBoost)
            }
          }
        }
      }
    }
  }

  function modeCaption(mode) {
    if (mode === "eco") return "Maximizes battery run time"
    if (mode === "comfort") return "Balanced heat and noise"
    if (mode === "sport") return "Maximum CPU and GPU power"
    return ""
  }

  function nextFan(delta) {
    var modes = fanModes
    if (modes.length === 0) return ""
    var at = modes.indexOf(msi.fanMode)
    if (at < 0) at = 0
    return modes[(at + 1) % modes.length]
  }

  // Keyboard 'f' cycles the same list the FAN section shows.
  function cycleFan() {
    if (msi.hasFanCurve) {
      var presets = Model.fanPresetNames()
      var match = Model.matchingPreset(msi)
      var at = presets.indexOf(match)
      if (msi.fanMode !== "advanced" || at < 0) {
        msi.applyFanPreset(presets[0])
        return
      }
      if (at + 1 < presets.length) msi.applyFanPreset(presets[at + 1])
      else if (fanModes.indexOf("advanced") >= 0) msi.setFanMode("advanced")
      return
    }
    var next = nextFan(1)
    if (next !== "") msi.setFanMode(next)
  }

  function fanDisplay() {
    var match = Model.matchingPreset(msi)
    if (match !== "") return Model.fanPresetLabel(match)
    return Model.fanModeName(msi.fanMode)
  }

  component ModeRow: CursorSurface {
    id: modeRow
    property string rowName: ""
    property string text: ""
    property string caption: ""
    property bool selected: false

    signal clicked()

    hasCursor: root.rowHasCursor(rowName)
    foreground: root.foreground
    implicitHeight: modeLayout.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.focusRow(modeRow.rowName)
      onClicked: modeRow.clicked()
    }

    RowLayout {
      id: modeLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: modeRow.text
          color: root.foreground
          opacity: modeRow.selected ? 1.0 : 0.75
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          visible: modeRow.caption !== ""
          Layout.fillWidth: true
          text: modeRow.caption
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        textFormat: Text.PlainText
        Layout.alignment: Qt.AlignVCenter
        text: "󰄬"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        opacity: modeRow.selected ? 1.0 : 0.0
      }
    }
  }

  component ToggleRow: CursorSurface {
    id: toggleRow
    property string rowName: ""
    property string label: ""
    property string caption: ""
    property bool checked: false

    signal toggled()

    hasCursor: root.rowHasCursor(rowName)
    foreground: root.foreground
    implicitHeight: toggleContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.focusRow(toggleRow.rowName)
      onClicked: toggleRow.toggled()
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      ColumnLayout {
        id: toggleContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: toggleRow.label
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: toggleRow.caption
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      ToggleSwitch {
        Layout.alignment: Qt.AlignVCenter
        checked: toggleRow.checked
        hasCursor: toggleRow.hasCursor
        foreground: root.foreground
        onToggled: toggleRow.toggled()
      }
    }
  }

  component StatRow: Item {
    id: row
    property string label: ""
    property string value: ""
    property color valueColor: root.foreground

    width: parent ? parent.width : 0
    implicitHeight: Math.max(labelText.implicitHeight, valueText.implicitHeight)
    height: implicitHeight

    Text {
      id: labelText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: row.label
      color: Qt.darker(root.foreground, 1.35)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Text {
      id: valueText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: row.value
      color: row.valueColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      width: Math.min(implicitWidth, parent.width - labelText.implicitWidth - Style.space(12))
      elide: Text.ElideRight
      horizontalAlignment: Text.AlignRight
    }
  }
}