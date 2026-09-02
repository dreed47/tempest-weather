import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Detail popup + weather fetch for the Tempest Weather bar widget.
//
// Data comes straight from the station owner's WeatherFlow "Better Forecast"
// endpoint (https://weatherflow.github.io/Tempest/api/), so readings match the
// Tempest app rather than a modelled forecast. Credentials are read from the
// widget settings in shell.json, falling back to $TEMPEST_STATION_ID and
// $TEMPEST_TOKEN in the shell's environment.
//
// The gear in the popup opens an inline settings form (station ID, token,
// units, refresh interval); Save persists each field to this widget's
// shell.json entry via `omarchy-bar set`, which the shell hot-reloads.
Panel {
  id: root
  moduleName: "io.github.dreed47.tempest-weather"
  ipcTarget: "io.github.dreed47.tempest-weather"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar identifies the popup by the widget mounted in its slot
  // (BarWidget.qml), not by this nested panel. hostWidget is that widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Configuration ------------------------------------------------------

  readonly property string stationId: {
    var v = String(setting("stationId", "")).replace(/^\s+|\s+$/g, "")
    return v !== "" ? v : String(Quickshell.env("TEMPEST_STATION_ID") || "").replace(/^\s+|\s+$/g, "")
  }
  readonly property string token: {
    var v = String(setting("token", "")).replace(/^\s+|\s+$/g, "")
    return v !== "" ? v : String(Quickshell.env("TEMPEST_TOKEN") || "").replace(/^\s+|\s+$/g, "")
  }
  readonly property bool configured: stationId !== "" && token !== ""

  readonly property string units: Model.normalizedUnits(setting("units", "metric"))
  readonly property var unitParams: Model.apiUnitParams(units)
  readonly property var unitLabels: Model.unitLabels(units)

  // Auto-refresh interval in minutes; clamped so a typo cannot hammer the API.
  readonly property int refreshMinutes: Math.max(5, parseInt(setting("refreshMinutes", 10), 10) || 10)

  readonly property string requestUrl: "https://swd.weatherflow.com/swd/rest/better_forecast"
    + "?station_id=" + encodeURIComponent(stationId)
    + "&token=" + encodeURIComponent(token)
    + "&units_temp=" + unitParams.temp
    + "&units_wind=" + unitParams.wind
    + "&units_pressure=" + unitParams.pressure
    + "&units_distance=" + unitParams.distance
    + "&units_precip=" + unitParams.precip

  // ---- Parsed report (kept on failure so stale data stays visible) -------

  property var report: null
  property int fetchRetries: 0

  readonly property var current: Model.currentConditions(report)
  // Today plus the next two days. The popup is width-constrained; three cells
  // is what fits cleanly and matches Omarchy's built-in weather widget.
  readonly property var forecastDays: Model.forecastDays(report, 3, function(d) { return Qt.formatDate(d, "ddd") })

  readonly property string deg: String.fromCharCode(0x00b0)
  readonly property string tempStr: current ? Model.roundedTemp(current.air_temperature) : ""
  readonly property string glyphStr: current ? Model.iconForTempest(current.icon) : ""
  readonly property string label: glyphStr !== "" && tempStr !== "" ? (glyphStr + "  " + tempStr + deg) : ""
  readonly property string tooltip: current && current.conditions ? String(current.conditions) : ""

  // ---- Lifecycle (mirrors the first-party weather panel) ----------------

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (root.editingSettings) root.cancelEditingSettings()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- Fetch ----------------------------------------------------------

  function refresh() {
    fetchRetries = 0
    if (!configured) return
    if (!fetchProc.running) fetchProc.running = true
  }

  function scheduleRetry() {
    if (fetchRetries >= 3) return
    fetchRetries++
    retryTimer.restart()
  }

  // Lines for the right-click desktop notification: headline first, then one
  // field per line. Consumed by BarWidget.notify().
  function statusLines() {
    if (!configured) return ["Tempest Weather is not configured", "Set the station ID and token from the gear in the popup."]
    return Model.summaryLines(report, units)
  }
  readonly property string statusGlyph: glyphStr

  Process {
    id: fetchProc
    command: ["curl", "-fsS", "--max-time", "10", root.requestUrl]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").replace(/^\s+|\s+$/g, "")
        if (raw === "") { root.scheduleRetry(); return }
        try {
          var parsed = JSON.parse(raw)
          if (!parsed || !parsed.current_conditions) { root.scheduleRetry(); return }
          root.report = parsed
          root.fetchRetries = 0
        } catch (e) {
          root.scheduleRetry()
        }
      }
    }
  }

  Timer {
    id: retryTimer
    interval: 3000
    onTriggered: if (!fetchProc.running) fetchProc.running = true
  }

  Timer {
    id: refreshTimer
    interval: root.refreshMinutes * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Re-fetch immediately when the unit choice or credentials change.
  onRequestUrlChanged: Qt.callLater(root.refresh)

  // ---- Inline settings form -------------------------------------------
  //
  // Fields are persisted one at a time to this widget's shell.json layout
  // entry via `omarchy-bar set <id> <key> <value>`. The shell watches
  // shell.json and patches the live widget's `settings` in place, so the
  // readonly config properties above re-evaluate and a refetch kicks off.

  property bool editingSettings: false
  property bool savingSettings: false
  property string draftStation: ""
  property string draftToken: ""
  property string draftUnits: "metric"
  property string draftRefresh: "10"
  property var settingsSaveQueue: []

  function startEditingSettings() {
    draftStation = String(setting("stationId", "") || "")
    draftToken = String(setting("token", "") || "")
    draftUnits = root.units
    draftRefresh = String(root.refreshMinutes)
    savingSettings = false
    editingSettings = true
    Qt.callLater(function() {
      stationField.forceActiveFocus()
      stationField.selectAll()
    })
  }

  function cancelEditingSettings() {
    editingSettings = false
    savingSettings = false
    settingsSaveQueue = []
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function saveSettings() {
    if (savingSettings) return
    savingSettings = true
    var refresh = parseInt(draftRefresh, 10)
    if (isNaN(refresh) || refresh < 5) refresh = 5
    settingsSaveQueue = [
      ["stationId", draftStation.replace(/^\s+|\s+$/g, "")],
      ["token", draftToken.replace(/^\s+|\s+$/g, "")],
      ["units", Model.normalizedUnits(draftUnits)],
      ["refreshMinutes", String(refresh)]
    ]
    runNextSettingsSave()
  }

  function runNextSettingsSave() {
    if (settingsSaveQueue.length === 0) {
      savingSettings = false
      editingSettings = false
      Qt.callLater(root.refresh)
      Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
      return
    }
    var pair = settingsSaveQueue.shift()
    settingsSaveProc.command = ["omarchy-bar", "set", root.ipcTarget, pair[0], pair[1]]
    settingsSaveProc.running = true
  }

  Process {
    id: settingsSaveProc
    onExited: function(exitCode) { root.runNextSettingsSave() }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function settings(): void { root.openFromHotkey(); root.startEditingSettings() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    // Anchor the card under the pill (the built-in right-section panels do the
    // same). centerOnBar is only for a center-section widget like the stock
    // weather one.
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(weatherColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingSettings
      onReturnRequested: root.startEditingSettings()
      onCloseRequested: root.editingSettings ? root.cancelEditingSettings() : root.close()
      onTabRequested: function(direction) { if (!root.editingSettings) root.switchPanel(direction) }

      Flickable {
        id: weatherScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: weatherColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: weatherColumn
          width: weatherScroll.width
          spacing: Style.space(14)

          // ================= DATA VIEW =================
          Column {
            id: dataView
            visible: !root.editingSettings
            width: parent.width
            spacing: Style.space(14)

          // ---- Hero row: big glyph + temperature on the left, stats stacked right.
          Item {
            width: parent.width
            height: Math.max(heroLeft.height, heroRight.height)

            Row {
              id: heroLeft
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(16)

              Text {
                id: heroIcon
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: 5
                text: root.glyphStr || String.fromCharCode(0x2014)
                color: root.bar ? root.bar.foreground : "white"
                font.family: root.bar ? root.bar.fontFamily : "monospace"
                font.pixelSize: 64
              }

              Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  id: tempBig
                  textFormat: Text.PlainText
                  text: root.tempStr || String.fromCharCode(0x2014)
                  color: root.bar ? root.bar.foreground : "white"
                  font.family: root.bar ? root.bar.fontFamily : "monospace"
                  font.pixelSize: 56
                  font.bold: true
                }
                Text {
                  textFormat: Text.PlainText
                  text: root.current ? (root.deg + root.unitLabels.temp) : ""
                  color: root.bar ? root.bar.foreground : "white"
                  font.family: root.bar ? root.bar.fontFamily : "monospace"
                  font.pixelSize: Style.font.display
                  anchors.top: tempBig.top
                  anchors.topMargin: Style.space(10)
                }
              }
            }

            Column {
              id: heroRight
              anchors.right: parent.right
              anchors.rightMargin: Style.space(20)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(12)

              Text {
                visible: root.tooltip !== ""
                textFormat: Text.PlainText
                text: root.tooltip.toUpperCase()
                color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "gray"
                font.family: root.bar ? root.bar.fontFamily : "monospace"
                font.pixelSize: Style.font.body
                font.letterSpacing: 1
                anchors.right: parent.right
              }

              Row {
                id: statRowTop
                visible: !!root.current
                anchors.right: parent.right
                spacing: Style.space(30)

                Repeater {
                  model: root.current ? [
                    { k: "FEELS", v: Model.roundedTemp(root.current.feels_like) + root.deg + root.unitLabels.temp },
                    { k: "WIND", v: Model.roundedTo(root.current.wind_avg, 0) + " " + root.unitLabels.wind
                        + (root.current.wind_direction_cardinal ? " " + root.current.wind_direction_cardinal : "") },
                    { k: "HUMID", v: Model.roundedTemp(root.current.relative_humidity) + "%" }
                  ] : []

                  Column {
                    required property var modelData
                    spacing: Style.space(5)
                    Text {
                      text: modelData.k
                      color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "gray"
                      font.family: root.bar ? root.bar.fontFamily : "monospace"
                      font.pixelSize: Style.font.bodySmall
                      font.letterSpacing: 1
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: modelData.v
                      color: root.bar ? root.bar.foreground : "white"
                      font.family: root.bar ? root.bar.fontFamily : "monospace"
                      font.pixelSize: Style.font.title
                    }
                  }
                }
              }

              Row {
                id: statRowBottom
                visible: !!root.current
                anchors.right: parent.right
                spacing: Style.space(30)

                Repeater {
                  model: root.current ? [
                    { k: "PRESSURE", v: Model.roundedTo(root.current.sea_level_pressure, 2) + " " + root.unitLabels.pressure },
                    { k: "TREND", v: Model.pressureTrendLabel(root.current.pressure_trend) },
                    { k: "UV", v: Model.roundedTo(root.current.uv, 0) },
                    { k: "DEW", v: Model.roundedTemp(root.current.dew_point) + root.deg + root.unitLabels.temp }
                  ] : []

                  Column {
                    required property var modelData
                    spacing: Style.space(5)
                    Text {
                      text: modelData.k
                      color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "gray"
                      font.family: root.bar ? root.bar.fontFamily : "monospace"
                      font.pixelSize: Style.font.bodySmall
                      font.letterSpacing: 1
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: modelData.v
                      color: root.bar ? root.bar.foreground : "white"
                      font.family: root.bar ? root.bar.fontFamily : "monospace"
                      font.pixelSize: Style.font.body
                    }
                  }
                }
              }
            }
          }

          // ---- Status messages.
          Text {
            visible: !root.configured
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Not configured. Click the gear to set the station ID and token, "
              + "or export TEMPEST_STATION_ID and TEMPEST_TOKEN in the shell's environment."
            color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "gray"
            font.family: root.bar ? root.bar.fontFamily : "monospace"
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          Text {
            visible: root.configured && !root.current
            text: "Fetching from the Tempest station..."
            color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "gray"
            font.family: root.bar ? root.bar.fontFamily : "monospace"
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          // ---- Divider.
          Rectangle {
            visible: root.forecastDays.length > 0
            width: parent.width
            height: Style.spacing.hairline
            color: root.bar ? root.bar.foreground : "gray"
            opacity: 0.12
          }

          // ---- Forecast row.
          Item {
            visible: root.forecastDays.length > 0
            width: parent.width
            height: forecastRow.height

            Row {
              id: forecastRow
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(28)

              Repeater {
                model: root.forecastDays

                Row {
                  required property var modelData
                  spacing: Style.space(10)

                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.icon
                    color: root.bar ? root.bar.foreground : "white"
                    font.family: root.bar ? root.bar.fontFamily : "monospace"
                    font.pixelSize: Style.font.display
                  }

                  Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)

                    Text {
                      textFormat: Text.PlainText
                      text: (modelData.name || "").toUpperCase()
                      color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "gray"
                      font.family: root.bar ? root.bar.fontFamily : "monospace"
                      font.pixelSize: Style.font.caption
                      font.letterSpacing: 1
                    }

                    Row {
                      spacing: Style.space(6)

                      Text {
                        textFormat: Text.PlainText
                        text: modelData.high + root.deg
                        color: root.bar ? root.bar.foreground : "white"
                        font.family: root.bar ? root.bar.fontFamily : "monospace"
                        font.pixelSize: Style.font.body
                      }
                      Text {
                        textFormat: Text.PlainText
                        text: modelData.low + root.deg
                        color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "gray"
                        font.family: root.bar ? root.bar.fontFamily : "monospace"
                        font.pixelSize: Style.font.body
                      }
                      Text {
                        textFormat: Text.PlainText
                        visible: modelData.precip !== "" && modelData.precip !== "0"
                        text: modelData.precip + "%"
                        color: root.bar ? Qt.darker(root.bar.foreground, 1.6) : "gray"
                        font.family: root.bar ? root.bar.fontFamily : "monospace"
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }
              }
            }
          }
          }
          // =============== END DATA VIEW ===============

          // ================= SETTINGS VIEW =================
          Column {
            id: settingsView
            visible: root.editingSettings
            width: parent.width - Style.space(32)
            x: Style.space(16)
            spacing: Style.space(14)

            Text {
              text: "TEMPEST WEATHER SETTINGS"
              color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "gray"
              font.family: root.bar ? root.bar.fontFamily : "monospace"
              font.pixelSize: Style.font.bodySmall
              font.letterSpacing: 1
            }

            // -- Station ID
            Column {
              width: parent.width
              spacing: Style.space(4)
              Text {
                text: "STATION ID"
                color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "gray"
                font.family: root.bar ? root.bar.fontFamily : "monospace"
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
              TextField {
                id: stationField
                width: parent.width
                enabled: !root.savingSettings
                placeholderText: "e.g. 12345"
                text: root.draftStation
                foreground: root.bar ? root.bar.foreground : "white"
                font.family: root.bar ? root.bar.fontFamily : "monospace"
                inputMethodHints: Qt.ImhDigitsOnly
                onTextChanged: root.draftStation = text
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) { root.cancelEditingSettings(); event.accepted = true }
                  else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.saveSettings(); event.accepted = true }
                }
              }
            }

            // -- Token
            Column {
              width: parent.width
              spacing: Style.space(4)
              Text {
                text: "API TOKEN  (tempestwx.com/settings/tokens)"
                color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "gray"
                font.family: root.bar ? root.bar.fontFamily : "monospace"
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
              TextField {
                id: tokenField
                width: parent.width
                enabled: !root.savingSettings
                password: true
                placeholderText: "paste personal access token"
                text: root.draftToken
                foreground: root.bar ? root.bar.foreground : "white"
                font.family: root.bar ? root.bar.fontFamily : "monospace"
                onTextChanged: root.draftToken = text
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) { root.cancelEditingSettings(); event.accepted = true }
                  else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.saveSettings(); event.accepted = true }
                }
              }
            }

            // -- Units + refresh, side by side
            Row {
              width: parent.width
              spacing: Style.space(28)

              Column {
                spacing: Style.space(4)
                Text {
                  text: "UNITS"
                  color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "gray"
                  font.family: root.bar ? root.bar.fontFamily : "monospace"
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
                Row {
                  spacing: Style.space(8)
                  Repeater {
                    model: ["metric", "imperial"]
                    Rectangle {
                      required property var modelData
                      height: Style.space(28)
                      width: unitLabel.implicitWidth + Style.space(20)
                      radius: Style.cornerRadius
                      readonly property bool active: root.draftUnits === modelData
                      color: active
                        ? (root.bar ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "#333")
                        : "transparent"
                      border.width: 1
                      border.color: root.bar ? Qt.darker(root.bar.foreground, 2.0) : "gray"

                      Text {
                        id: unitLabel
                        anchors.centerIn: parent
                        text: modelData
                        color: root.bar ? root.bar.foreground : "white"
                        font.family: root.bar ? root.bar.fontFamily : "monospace"
                        font.pixelSize: Style.font.bodySmall
                      }
                      MouseArea {
                        anchors.fill: parent
                        enabled: !root.savingSettings
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.draftUnits = modelData
                      }
                    }
                  }
                }
              }

              Column {
                spacing: Style.space(4)
                Text {
                  text: "REFRESH (MIN)"
                  color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "gray"
                  font.family: root.bar ? root.bar.fontFamily : "monospace"
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
                TextField {
                  id: refreshField
                  width: Style.space(80)
                  enabled: !root.savingSettings
                  text: root.draftRefresh
                  foreground: root.bar ? root.bar.foreground : "white"
                  font.family: root.bar ? root.bar.fontFamily : "monospace"
                  inputMethodHints: Qt.ImhDigitsOnly
                  validator: IntValidator { bottom: 5; top: 240 }
                  onTextChanged: root.draftRefresh = text
                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape) { root.cancelEditingSettings(); event.accepted = true }
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.saveSettings(); event.accepted = true }
                  }
                }
              }
            }

            // -- Save / Cancel
            Row {
              spacing: Style.space(10)

              Rectangle {
                width: saveLabel.implicitWidth + Style.space(28)
                height: Style.space(30)
                radius: Style.cornerRadius
                color: root.bar ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "#444"
                opacity: root.savingSettings ? 0.6 : 1
                Text {
                  id: saveLabel
                  anchors.centerIn: parent
                  text: root.savingSettings ? "Saving..." : "Save"
                  color: root.bar ? root.bar.foreground : "white"
                  font.family: root.bar ? root.bar.fontFamily : "monospace"
                  font.pixelSize: Style.font.bodySmall
                }
                MouseArea {
                  anchors.fill: parent
                  enabled: !root.savingSettings
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.saveSettings()
                }
              }

              Rectangle {
                width: cancelLabel.implicitWidth + Style.space(28)
                height: Style.space(30)
                radius: Style.cornerRadius
                color: "transparent"
                border.width: 1
                border.color: root.bar ? Qt.darker(root.bar.foreground, 2.0) : "gray"
                Text {
                  id: cancelLabel
                  anchors.centerIn: parent
                  text: "Cancel"
                  color: root.bar ? Qt.darker(root.bar.foreground, 1.3) : "gray"
                  font.family: root.bar ? root.bar.fontFamily : "monospace"
                  font.pixelSize: Style.font.bodySmall
                }
                MouseArea {
                  anchors.fill: parent
                  enabled: !root.savingSettings
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.cancelEditingSettings()
                }
              }
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Saved to this widget's entry in ~/.config/omarchy/shell.json. "
                + "Leave the fields blank to fall back to $TEMPEST_STATION_ID / $TEMPEST_TOKEN."
              color: root.bar ? Qt.darker(root.bar.foreground, 1.6) : "gray"
              font.family: root.bar ? root.bar.fontFamily : "monospace"
              font.pixelSize: Style.font.caption
              font.italic: true
            }
          }
          // =============== END SETTINGS VIEW ===============
        }
      }

      // ---- Gear: opens / closes the settings form. Top-right overlay.
      Rectangle {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(10)
        width: Style.space(26)
        height: Style.space(26)
        radius: Style.cornerRadius
        color: gearArea.containsMouse
          ? (root.bar ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "#333")
          : "transparent"

        Text {
          anchors.centerIn: parent
          text: root.editingSettings ? String.fromCharCode(0x00d7) : String.fromCharCode(0xf013)
          color: root.bar ? Qt.darker(root.bar.foreground, 1.3) : "gray"
          font.family: root.bar ? root.bar.fontFamily : "monospace"
          font.pixelSize: root.editingSettings ? Style.font.title : Style.font.body
        }
        MouseArea {
          id: gearArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.editingSettings ? root.cancelEditingSettings() : root.startEditingSettings()
        }
      }
    }
  }
}
