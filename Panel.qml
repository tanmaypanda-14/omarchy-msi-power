import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// MSI Center summary in the bar: the EC sensors and the same seven settings
// as the desktop app, plus read-only CPU/GPU clocks and memory.
//
//   Sensors  CPU temperature, CPU and GPU clock, memory, fan speed (RPM),
//            fan level, AC state
//   Settings power mode, fan mode, cooler boost, charge limit,
//            keyboard backlight, Fn/Win swap, webcam block
//
// Every write is the same sysfs write msi-center makes. No raw EC writes,
// no fan-curve editor, no root helper.
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

  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property bool hideWhenUnsupported: setting("hideWhenUnsupported", true) === true
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color warn: Qt.lighter(urgent, 1.35)
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color accent: Color.accent
  readonly property color ok: Color.ok !== undefined ? Color.ok : accent
  // Same fixed threshold the app's temperature tint uses; not a setting.
  readonly property int tempHotAt: 85
  readonly property bool tempHot: msi.hasCpuSensor && msi.cpuTemp >= tempHotAt
  readonly property bool hasSensors: msi.hasCpuSensor || msi.hasCpuClock
    || msi.hasGpuClock || msi.hasRam || msi.hasFanRpm || msi.fanLevel >= 0
  readonly property color barIconColor: !msi.present
    ? Qt.darker(barForeground, 1.55)
    : ((msi.coolerBoost || root.tempHot) ? urgent : barForeground)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var shiftModes: Model.supportedShiftModes(msi)
  readonly property var fanModes: Model.supportedFanModes(msi)
  readonly property var batteryLimits: Model.batteryLimits()

  // Every focusable row in order, so j/k never land on a hidden control.
  readonly property var cursorRows: {
    var rows = []
    for (var i = 0; i < shiftModes.length; i++) rows.push("shift:" + shiftModes[i])
    for (var j = 0; j < fanModes.length; j++) rows.push("fan:" + fanModes[j])
    if (msi.hasCooler) rows.push("cooler")
    for (var b = 0; b < batteryLimits.length; b++) rows.push("battery:" + batteryLimits[b].limit)
    if (msi.hasKbd) rows.push("kbd")
    if (msi.hasFnSwap) rows.push("fnswap")
    if (msi.hasWebcam) rows.push("webcam")
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
    else if (name.indexOf("fan:") === 0) msi.setFanMode(name.substring(4))
    else if (name.indexOf("battery:") === 0) msi.setBatteryLimit(parseInt(name.substring(8), 10))
    else if (name === "cooler") msi.setCoolerBoost(!msi.coolerBoost)
    else if (name === "kbd") msi.cycleKeyboard()
    else if (name === "fnswap") msi.toggleFnSwap()
    else if (name === "webcam") msi.toggleWebcam()
  }

  function fmtPercent(p) {
    return (p === null || p === undefined || isNaN(Number(p)) || Number(p) < 0)
      ? "—" : Math.round(Number(p)) + "%"
  }

  function tempColor(t, warnAt, critAt) {
    if (t === null || t === undefined || Number(t) < 0) return root.foreground
    var n = Number(t)
    if (n >= critAt) return root.urgent
    if (n >= warnAt) return root.warn
    return root.foreground
  }

  function fanDisplay() {
    return msi.fanMode !== "" ? Model.fanModeName(msi.fanMode) : "—"
  }

  visible: msi.present || !hideWhenUnsupported
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursorIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    msi.refresh()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: msi
    settings: root.settings
    pluginDir: root.pluginDir
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { msi.refresh(); return "ok" }
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
    text: "󰓅"
    foreground: root.barIconColor
    tooltipText: "MSI Center"
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
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(980))

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
        if (key === "r") msi.refresh()
        else if (key === "m") msi.cycleShift(1)
        else if (key === "f") {
          var modes = fanModes
          if (modes.length === 0) return
          var at = modes.indexOf(msi.fanMode)
          msi.setFanMode(modes[(at + 1) % modes.length])
        }
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
          spacing: Style.space(9)

          PanelHero {
            id: hero
            width: parent.width
            title: msi.model !== "" ? msi.model : "MSI Laptop"
            detail: msi.present && msi.ecFirmware !== ""
              ? "EC " + msi.ecFirmware + " · msi-ec" : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: msi.present ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "󰓅"
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

          // ------------------------------------------------------- SENSORS
          Column {
            visible: root.hasSensors
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "SENSORS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            GridLayout {
              width: parent.width
              columns: 2
              rowSpacing: Style.space(8)
              columnSpacing: Style.space(8)

              StatCard {
                visible: msi.hasCpuSensor
                Layout.fillWidth: true
                label: "CPU TEMP"
                value: msi.cpuTemp >= 0 ? msi.cpuTemp + "°C" : "—"
                valueColor: root.tempColor(msi.cpuTemp, 75, 85)
              }

              StatCard {
                visible: msi.hasCpuClock
                Layout.fillWidth: true
                label: "CPU CLOCK"
                value: Model.fmtClock(msi.cpuMhz)
              }

              StatCard {
                visible: msi.hasGpuClock
                Layout.fillWidth: true
                label: "GPU CLOCK"
                value: Model.fmtClock(msi.gpuMhz)
              }

              StatCard {
                visible: msi.hasRam
                Layout.fillWidth: true
                label: "MEMORY"
                value: Model.fmtMemory(msi.ramUsedKb, msi.ramTotalKb)
              }

              StatCard {
                visible: msi.hasFanRpm
                Layout.fillWidth: true
                label: "FAN SPEED"
                value: msi.fanRpm > 0 ? msi.fanRpm + " rpm" : "OFF"
              }

              StatCard {
                visible: msi.fanLevel >= 0
                Layout.fillWidth: true
                label: "FAN LEVEL"
                value: root.fmtPercent(msi.fanLevel)
              }
            }

            RowLayout {
              visible: msi.hasBattery
              width: parent.width
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: "POWER"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 0.6
              }

              Text {
                textFormat: Text.PlainText
                text: msi.acOnline ? "On AC power" : "On battery"
                color: msi.acOnline ? root.ok : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          PanelSeparator {
            visible: root.hasSensors && shiftModes.length > 0
            foreground: root.foreground
          }

          // ----------------------------------------------------- POWER MODE
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
                  caption: Model.shiftModeCaption(modelData)
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

          // --------------------------------------------------------- FAN
          Column {
            visible: fanModes.length > 0 || msi.hasCooler
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "FAN"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              visible: fanModes.length > 0
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: fanModes
                ModeRow {
                  required property var modelData
                  width: parent.width
                  rowName: "fan:" + modelData
                  text: Model.fanModeName(modelData)
                  caption: Model.fanModeCaption(modelData)
                  selected: msi.fanMode === modelData
                  onClicked: msi.setFanMode(modelData)
                }
              }
            }

            ToggleRow {
              visible: msi.hasCooler
              width: parent.width
              rowName: "cooler"
              label: "Cooler Boost"
              caption: "Runs the fan at maximum"
              checked: msi.coolerBoost
              onToggled: msi.setCoolerBoost(!msi.coolerBoost)
            }
          }

          PanelSeparator {
            visible: msi.hasBattery && msi.batteryLimit > 0
            foreground: root.foreground
          }

          // ------------------------------------------------------ BATTERY
          Column {
            visible: msi.hasBattery && msi.batteryLimit > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "CHARGE LIMIT"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.batteryLimits

                LimitChip {
                  required property var modelData
                  Layout.fillWidth: true
                  limit: modelData.limit
                  label: modelData.label
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Lower limits extend battery life when the laptop stays plugged in."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator {
            visible: msi.hasKbd || msi.hasFnSwap || msi.hasWebcam
            foreground: root.foreground
          }

          // ------------------------------------------------------- SYSTEM
          Column {
            visible: msi.hasKbd || msi.hasFnSwap || msi.hasWebcam
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "SYSTEM"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            ToggleRow {
              visible: msi.hasKbd
              width: parent.width
              rowName: "kbd"
              label: "Keyboard backlight"
              caption: Model.kbdLabel(msi)
              checked: msi.kbdLevel > 0
              onToggled: msi.cycleKeyboard()
            }

            ToggleRow {
              visible: msi.hasFnSwap
              width: parent.width
              rowName: "fnswap"
              label: "Swap Fn / Win keys"
              caption: Model.fnSwapLabel(msi)
              checked: msi.fnSwap
              onToggled: msi.toggleFnSwap()
            }

            ToggleRow {
              visible: msi.hasWebcam
              width: parent.width
              rowName: "webcam"
              label: "Block webcam"
              caption: "EC-level kill switch"
              checked: msi.webcamBlocked
              onToggled: msi.toggleWebcam()
            }
          }
        }
      }
    }
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


  component LimitChip: Rectangle {
    id: chip
    property int limit: 0
    property string label: ""
    readonly property bool selected: msi.batteryLimit === limit
    readonly property bool hasCursor: root.rowHasCursor("battery:" + limit)

    radius: Style.space(8)
    implicitHeight: Style.space(38)
    color: selected
      ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
    border.width: hasCursor ? Style.space(2) : Style.space(1)
    border.color: hasCursor
      ? root.foreground
      : (selected ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.55)
                  : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10))

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.focusRow("battery:" + chip.limit)
      onClicked: msi.setBatteryLimit(chip.limit)
    }

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: chip.label
      color: root.foreground
      opacity: chip.selected ? 1.0 : 0.8
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.weight: chip.selected ? Font.DemiBold : Font.Normal
    }
  }

  component StatCard: Rectangle {
    id: card
    property string label: ""
    property string value: ""
    property color valueColor: root.foreground

    radius: Style.space(10)
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
    border.width: Style.space(1)
    border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.09)
    implicitHeight: Style.space(54)

    ColumnLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      anchors.topMargin: Style.space(7)
      anchors.bottomMargin: Style.space(7)
      spacing: 0

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: card.label
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 0.6
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: card.value
        color: card.valueColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.weight: Font.DemiBold
        elide: Text.ElideRight
      }
    }
  }

}
