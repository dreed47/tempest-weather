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

  // The headless alert service (AlertService.qml). Read-only here — the popup
  // shows a summary of any active NWS alert it is tracking.
  readonly property var alertSvc: root.bar && root.bar.shell
    ? root.bar.shell.serviceFor("io.github.dreed47.tempest-weather") : null
  readonly property var nwsAlerts: alertSvc && alertSvc.nwsAlerts ? alertSvc.nwsAlerts : []
  property bool nwsExpanded: false
  readonly property string nwsPointUrl: {
    if (!alertSvc || !alertSvc.lat || !alertSvc.lon) return ""
    return "https://forecast.weather.gov/MapClick.php?lat=" + alertSvc.lat + "&lon=" + alertSvc.lon
  }
  function openNwsPage() {
    if (nwsPointUrl === "") return
    // omarchy-launch-browser is the shell's own URL opener (systemd-run +
    // uwsm-app under the Wayland session); a bare `xdg-open` from here does
    // not reliably spawn the browser.
    Quickshell.execDetached(["omarchy-launch-browser", nwsPointUrl])
  }

  // ---- Configuration ------------------------------------------------------

  // Explicit station id, from the widget setting or the environment. Blank is
  // fine: the token belongs to a WeatherFlow account, and /stations lists that
  // account's stations, so a single-station account is auto-detected.
  readonly property string configuredStationId: {
    var v = String(setting("stationId", "")).replace(/^\s+|\s+$/g, "")
    return v !== "" ? v : String(Quickshell.env("TEMPEST_STATION_ID") || "").replace(/^\s+|\s+$/g, "")
  }
  // Filled from GET /stations when no station id is configured.
  property string discoveredStationId: ""
  readonly property string stationId: configuredStationId !== "" ? configuredStationId : discoveredStationId

  readonly property string token: {
    var v = String(setting("token", "")).replace(/^\s+|\s+$/g, "")
    return v !== "" ? v : String(Quickshell.env("TEMPEST_TOKEN") || "").replace(/^\s+|\s+$/g, "")
  }
  readonly property bool hasToken: token !== ""
  readonly property bool configured: hasToken && stationId !== ""

  onTokenChanged: {
    discoveredStationId = ""
    if (!hasToken) report = null   // drop stale data when the token is removed
    Qt.callLater(maybeDiscoverStation)
  }

  function maybeDiscoverStation() {
    if (!hasToken || configuredStationId !== "" || discoveredStationId !== "" || stationsProc.running) return
    stationsProc.running = true
  }

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
  readonly property string neutralGlyph: String.fromCharCode(0xe33d) // wi-cloud

  // The pill always shows something once the widget is enabled: the condition
  // glyph + temperature when data is in, otherwise a neutral cloud so a fresh
  // install is visible and clicking it opens the popup (and its settings form).
  readonly property string label: (glyphStr !== "" && tempStr !== "")
    ? (glyphStr + "  " + tempStr + deg)
    : neutralGlyph

  // Condition word shown under the hero temperature (e.g. "CLEAR").
  readonly property string conditionText: current && current.conditions ? String(current.conditions) : ""

  // Bar-pill hover tooltip — names the station so it's clear this is local data.
  readonly property string tooltip: current
    ? (stationName !== "" ? (stationName + " - your Tempest station") : "Your Tempest station")
    : (root.configured ? "Tempest Weather" : "Tempest Weather - click to set up")

  // ---- "Live from your own station" header ------------------------------

  readonly property string stationName: report && report.location_name
    ? String(report.location_name).replace(/^\s+|\s+$/g, "") : ""
  readonly property int readingEpoch: current && current.time ? parseInt(current.time, 10) : 0

  // Re-evaluated every 60s (only while the popup is open) so the "Nm ago"
  // text advances between the far less frequent weather refreshes.
  property double nowMs: Date.now()
  Timer {
    interval: 60000
    repeat: true
    running: root.opened
    onRunningChanged: if (running) root.nowMs = Date.now()
    onTriggered: root.nowMs = Date.now()
  }

  readonly property string readingAge: Model.relativeAge(readingEpoch, nowMs)
  readonly property string headerText: {
    if (!current || readingAge === "") return ""
    var age = "LIVE · " + (readingAge === "just now" ? "JUST NOW" : "UPDATED " + readingAge.toUpperCase())
    return stationName !== "" ? (stationName.toUpperCase() + " — " + age) : age
  }

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
    maybeDiscoverStation()
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
    if (!configured) return ["Tempest Weather needs a token", "Open the popup, click the gear, and paste a Tempest API token."]
    return Model.summaryLines(report, units)
  }
  readonly property string statusGlyph: glyphStr

  // Resolve a station id from the token when none is configured. WeatherFlow
  // tokens are account-scoped; /stations returns every station on the account.
  Process {
    id: stationsProc
    command: ["curl", "-fsS", "--max-time", "10",
      "https://swd.weatherflow.com/swd/rest/stations?token=" + encodeURIComponent(root.token)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || "").replace(/^\s+|\s+$/g, ""))
          if (d && d.stations && d.stations.length > 0 && d.stations[0].station_id !== undefined
              && d.stations[0].station_id !== null)
            root.discoveredStationId = String(d.stations[0].station_id)
        } catch (e) {
          // Leave discoveredStationId empty; the popup still explains setup.
        }
      }
    }
  }

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
  property string draftAlertLightning: "off"
  property string draftAlertMaxDist: "0"
  property string draftAlertPrecip: "off"
  property string draftAlertNotify: "on"
  property string draftAlertPoll: "90"
  property string draftNotifyTimeout: "0"
  property string draftLightningSound: ""
  property string draftPrecipSound: ""
  property string draftSnowSound: ""
  property string draftAlertNws: "off"
  property string draftAlertNwsLevel: "warnings"
  property string draftNwsSound: ""
  property var settingsSaveQueue: []

  // Plugin install directory (…/plugins/<id>/), for the bundled default sounds
  // and the settings-form test buttons.
  readonly property string pluginDir: decodeURIComponent(
    Qt.resolvedUrl(".").toString().replace(/^file:\/\//, ""))
  function alertSoundPath(kind, draftOverride) {
    var o = String(draftOverride || "").replace(/^\s+|\s+$/g, "")
    if (o !== "") return o
    return pluginDir + "sounds/" + (kind === "lightning" ? "lightning.ogg"
      : kind === "snow" ? "snow.ogg"
      : kind === "nws" ? "nws.ogg" : "rain.ogg")
  }
  function draftSoundFor(kind) {
    return kind === "lightning" ? draftLightningSound
      : kind === "snow" ? draftSnowSound
      : kind === "nws" ? draftNwsSound : draftPrecipSound
  }
  function setDraftSound(kind, val) {
    if (kind === "lightning") draftLightningSound = val
    else if (kind === "snow") draftSnowSound = val
    else if (kind === "nws") draftNwsSound = val
    else draftPrecipSound = val
  }

  // ---- In-panel sound file browser ------------------------------------
  //
  // A native FileDialog opens as a normal toplevel behind this overlay-layer
  // popup, so it is unusable here. Instead this is a small directory list
  // rendered inside the settings card: `find` one level deep, show folders +
  // audio files, tap to descend / pick.

  property bool browsingSound: false
  property string browseKind: ""
  property string browseDir: ""
  property var browseEntries: []
  readonly property var browseAudioExt: ["wav", "ogg", "oga", "flac", "opus"]
  readonly property string homeDir: {
    var h = String(Quickshell.env("HOME") || "")
    return h !== "" ? h.replace(/\/$/, "") : "/"
  }

  function parentDir(p) {
    var s = String(p || "").replace(/\/+$/, "")
    if (s === "" || s === "/") return "/"
    var i = s.lastIndexOf("/")
    return i <= 0 ? "/" : s.slice(0, i)
  }

  function openSoundBrowse(kind) {
    browseKind = kind
    var cur = String(draftSoundFor(kind) || "").replace(/^\s+|\s+$/g, "")
    var start = cur !== "" ? parentDir(cur) : homeDir
    browsingSound = true
    listSoundDir(start)
  }

  function closeSoundBrowse() { browsingSound = false }

  function listSoundDir(dir) {
    browseDir = String(dir || "/")
    browseEntries = []
    browseProc.command = ["bash", "-c",
      'find "$1" -maxdepth 1 -mindepth 1 -printf "%y\\t%f\\n" 2>/dev/null', "bash", browseDir]
    browseProc.running = true
  }

  function applyBrowseListing(text) {
    var lines = String(text || "").split("\n")
    var dirs = [], files = []
    for (var i = 0; i < lines.length; i++) {
      var ln = lines[i]
      if (!ln) continue
      var tab = ln.indexOf("\t")
      if (tab < 0) continue
      var ty = ln.slice(0, tab), name = ln.slice(tab + 1)
      if (name === "" || name.charAt(0) === ".") continue   // skip dotfiles
      if (ty === "d") {
        dirs.push({ type: "dir", name: name, path: (browseDir === "/" ? "" : browseDir) + "/" + name })
      } else if (ty === "f" || ty === "l") {
        var ext = name.slice(name.lastIndexOf(".") + 1).toLowerCase()
        if (browseAudioExt.indexOf(ext) !== -1)
          files.push({ type: "file", name: name, path: (browseDir === "/" ? "" : browseDir) + "/" + name })
      }
    }
    dirs.sort(function(a, b) { return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1 })
    files.sort(function(a, b) { return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1 })
    var out = []
    if (browseDir !== "/") out.push({ type: "up", name: "..", path: parentDir(browseDir) })
    browseEntries = out.concat(dirs).concat(files)
  }

  function browsePick(entry) {
    if (!entry) return
    if (entry.type === "file") {
      setDraftSound(browseKind, entry.path)
      browsingSound = false
    } else {
      listSoundDir(entry.path)
    }
  }

  function onOffSetting(key, dflt) {
    return String(setting(key, dflt) || dflt).toLowerCase() === "on" ? "on" : "off"
  }

  function startEditingSettings() {
    draftStation = String(setting("stationId", "") || "")
    draftToken = String(setting("token", "") || "")
    draftUnits = root.units
    draftRefresh = String(root.refreshMinutes)
    draftAlertLightning = onOffSetting("alertLightning", "off")
    draftAlertMaxDist = String(setting("alertLightningMaxDistance", "0") || "0")
    draftAlertPrecip = onOffSetting("alertPrecipStart", "off")
    draftAlertNotify = onOffSetting("alertNotify", "on")
    draftAlertPoll = String(setting("alertPollSeconds", "90") || "90")
    draftNotifyTimeout = String(setting("alertNotifyTimeout", "0") || "0")
    draftLightningSound = String(setting("alertLightningSound", "") || "")
    draftPrecipSound = String(setting("alertPrecipSound", "") || "")
    draftSnowSound = String(setting("alertSnowSound", "") || "")
    draftAlertNws = onOffSetting("alertNws", "off")
    draftAlertNwsLevel = (function() {
      var v = String(setting("alertNwsLevel", "warnings") || "warnings").toLowerCase()
      return (v === "watches" || v === "advisories") ? v : "warnings"
    })()
    draftNwsSound = String(setting("alertNwsSound", "") || "")
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
    var maxDist = parseInt(draftAlertMaxDist, 10)
    if (isNaN(maxDist) || maxDist < 0) maxDist = 0
    var poll = parseInt(draftAlertPoll, 10)
    if (isNaN(poll) || poll < 60) poll = 60
    var notifyTimeout = parseInt(draftNotifyTimeout, 10)
    if (isNaN(notifyTimeout) || notifyTimeout < 0) notifyTimeout = 0
    settingsSaveQueue = [
      ["stationId", draftStation.replace(/^\s+|\s+$/g, "")],
      ["token", draftToken.replace(/^\s+|\s+$/g, "")],
      ["units", Model.normalizedUnits(draftUnits)],
      ["refreshMinutes", String(refresh)],
      ["alertLightning", draftAlertLightning === "on" ? "on" : "off"],
      ["alertLightningMaxDistance", String(maxDist)],
      ["alertPrecipStart", draftAlertPrecip === "on" ? "on" : "off"],
      ["alertNotify", draftAlertNotify === "on" ? "on" : "off"],
      ["alertNotifyTimeout", String(notifyTimeout)],
      ["alertPollSeconds", String(poll)],
      ["alertLightningSound", draftLightningSound.replace(/^\s+|\s+$/g, "")],
      ["alertPrecipSound", draftPrecipSound.replace(/^\s+|\s+$/g, "")],
      ["alertSnowSound", draftSnowSound.replace(/^\s+|\s+$/g, "")],
      ["alertNws", draftAlertNws === "on" ? "on" : "off"],
      ["alertNwsLevel", draftAlertNwsLevel],
      ["alertNwsSound", draftNwsSound.replace(/^\s+|\s+$/g, "")]
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

  // Plays a sound from the settings-form "test" buttons: the draft override if
  // set, otherwise the bundled default for that alert type.
  Process { id: soundTestProc }
  function testAlertSound(kind, draftOverride) {
    if (soundTestProc.running) return
    soundTestProc.command = ["pw-play", root.alertSoundPath(kind, draftOverride)]
    soundTestProc.running = true
  }

  Process {
    id: browseProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyBrowseListing(text)
    }
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

          // ---- Gear row: reserves its own strip so nothing overlaps it.
          //      Left side carries the "live from your own station" header.
          Item {
            width: parent.width
            height: Style.space(26)

            Text {
              id: liveHeader
              visible: !root.editingSettings && root.headerText !== ""
              anchors.left: parent.left
              anchors.leftMargin: Style.space(6)
              anchors.right: gearBtn.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.StyledText
              text: "<font color='" + Color.accent + "'>" + String.fromCharCode(0x25cf)
                + "</font>&#160;&#160;" + root.headerText
              elide: Text.ElideRight
              color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "gray"
              font.family: root.bar ? root.bar.fontFamily : "monospace"
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }

            Rectangle {
              id: gearBtn
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
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

          // ================= DATA VIEW =================
          Column {
            id: dataView
            visible: !root.editingSettings
            width: parent.width
            spacing: Style.space(14)

          // ---- NWS alert banner: shown while the service is tracking an
          //      active area warning. Summary inline, full text on demand, and
          //      a link to the weather.gov point page (radar + full details).
          Rectangle {
            visible: root.nwsAlerts.length > 0
            width: parent.width
            height: visible ? nwsInner.implicitHeight + Style.space(16) : 0
            radius: Style.cornerRadius
            color: "transparent"
            border.width: 1
            border.color: root.bar ? root.bar.urgent : "#cc4444"

            Column {
              id: nwsInner
              x: Style.space(10)
              y: Style.space(8)
              width: parent.width - Style.space(20)
              spacing: Style.space(6)

              Repeater {
                model: root.nwsAlerts
                Column {
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(2)
                  Text {
                    width: parent.width
                    text: String.fromCharCode(0xf071) + "  " + Model.nwsEventLabel(modelData)
                    color: root.bar ? root.bar.urgent : "#e66"
                    font.family: root.bar ? root.bar.fontFamily : "monospace"
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }
                  Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: String(modelData.headline || modelData.areaDesc || "")
                    color: root.bar ? root.bar.foreground : "white"
                    font.family: root.bar ? root.bar.fontFamily : "monospace"
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              Row {
                spacing: Style.space(16)
                Text {
                  text: root.nwsExpanded
                    ? (String.fromCharCode(0x25be) + " hide full text")
                    : (String.fromCharCode(0x25b8) + " full text")
                  color: root.bar ? Qt.darker(root.bar.foreground, 1.3) : "gray"
                  font.family: root.bar ? root.bar.fontFamily : "monospace"
                  font.pixelSize: Style.font.caption
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.nwsExpanded = !root.nwsExpanded
                  }
                }
                Text {
                  visible: root.nwsPointUrl !== ""
                  text: "details & radar on weather.gov  " + String.fromCharCode(0x2197)
                  color: Color.accent
                  font.family: root.bar ? root.bar.fontFamily : "monospace"
                  font.pixelSize: Style.font.caption
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openNwsPage()
                  }
                }
              }

              Rectangle {
                visible: root.nwsExpanded
                width: parent.width
                height: Style.space(200)
                radius: Style.cornerRadius
                color: "transparent"
                border.width: 1
                border.color: root.bar ? Qt.darker(root.bar.foreground, 1.7) : "gray"
                clip: true
                Flickable {
                  anchors.fill: parent
                  anchors.margins: Style.space(6)
                  contentWidth: width
                  contentHeight: nwsFull.implicitHeight
                  boundsBehavior: Flickable.StopAtBounds
                  interactive: contentHeight > height
                  Text {
                    id: nwsFull
                    width: parent.width
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                    text: {
                      var out = []
                      for (var i = 0; i < root.nwsAlerts.length; i++) {
                        var s = Model.nwsSummary(root.nwsAlerts[i])
                        out.push(s.event + "\n" + s.headline + "\n\n" + s.body)
                      }
                      return out.join("\n\n———\n\n")
                    }
                    color: root.bar ? Qt.darker(root.bar.foreground, 1.2) : "gray"
                    font.family: root.bar ? root.bar.fontFamily : "monospace"
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

          // ---- Hero row: big glyph + temperature + condition on the left,
          //      stats stacked on the right. The top-right corner is reserved
          //      for the gear (a sibling row above this one).
          Item {
            width: parent.width
            // Hidden on a fresh install (no token, no data) so only the
            // setup message shows.
            visible: root.current || root.configured
            height: visible ? Math.max(heroLeft.height, heroRight.height) : 0

            Column {
              id: heroLeft
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              Row {
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

              Text {
                visible: root.conditionText !== ""
                textFormat: Text.PlainText
                text: root.conditionText.toUpperCase()
                color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "gray"
                font.family: root.bar ? root.bar.fontFamily : "monospace"
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
                leftPadding: Style.space(2)
              }
            }

            Column {
              id: heroRight
              anchors.right: parent.right
              anchors.rightMargin: Style.space(20)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(12)

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
            text: root.hasToken
              ? "Looking up the station for this token..."
              : "Click the gear and paste a Tempest API token (from tempestwx.com/settings/tokens). "
                + "The station is detected automatically; set a station ID only for a multi-station account."
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

            // -- Station ID (optional; auto-detected from the token)
            Column {
              width: parent.width
              spacing: Style.space(4)
              Text {
                text: "STATION ID  (optional - blank = auto-detect)"
                color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "gray"
                font.family: root.bar ? root.bar.fontFamily : "monospace"
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
              TextField {
                id: stationField
                width: parent.width
                enabled: !root.savingSettings
                placeholderText: root.discoveredStationId !== ""
                  ? ("auto: " + root.discoveredStationId)
                  : "auto-detected from token"
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
                      // High contrast: selected = solid fill + inverted text;
                      // unselected = clear outline. The theme's accent often
                      // equals its foreground, so a tint alone is invisible.
                      color: active ? (root.bar ? root.bar.foreground : "#cacccc") : "transparent"
                      border.width: active ? 0 : 1
                      border.color: root.bar ? root.bar.foreground : "#cacccc"

                      Text {
                        id: unitLabel
                        anchors.centerIn: parent
                        text: modelData
                        color: parent.active
                          ? (root.bar ? root.bar.background : "#101315")
                          : (root.bar ? root.bar.foreground : "#cacccc")
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

            // -- Alerts (handled by the headless Service.qml, not this popup)
            Column {
              width: parent.width
              spacing: Style.space(12)

              Text {
                text: "ALERTS  (sound + notification)"
                color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "gray"
                font.family: root.bar ? root.bar.fontFamily : "monospace"
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }

              // Three on/off rows. Kept explicit (rather than a Repeater over a
              // prop-name model) so each highlight binding is a static property
              // path QML can actually track.
              Row {
                width: parent.width
                spacing: Style.space(12)
                Text {
                  width: Style.space(200)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "LIGHTNING STRIKE"
                  color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "gray"
                  font.family: root.bar ? root.bar.fontFamily : "monospace"
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
                Row {
                  spacing: Style.space(8)
                  Repeater {
                    model: ["off", "on"]
                    Rectangle {
                      required property var modelData
                      readonly property bool active: root.draftAlertLightning === modelData
                      height: Style.space(28)
                      width: lgLabel.implicitWidth + Style.space(20)
                      radius: Style.cornerRadius
                      color: active ? (root.bar ? root.bar.foreground : "#cacccc") : "transparent"
                      border.width: active ? 0 : 1
                      border.color: root.bar ? root.bar.foreground : "#cacccc"
                      Text {
                        id: lgLabel
                        anchors.centerIn: parent
                        text: modelData
                        color: parent.active
                          ? (root.bar ? root.bar.background : "#101315")
                          : (root.bar ? root.bar.foreground : "#cacccc")
                        font.family: root.bar ? root.bar.fontFamily : "monospace"
                        font.pixelSize: Style.font.bodySmall
                      }
                      MouseArea {
                        anchors.fill: parent
                        enabled: !root.savingSettings
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.draftAlertLightning = modelData
                      }
                    }
                  }
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(12)
                Text {
                  width: Style.space(200)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "RAIN / SNOW START"
                  color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "gray"
                  font.family: root.bar ? root.bar.fontFamily : "monospace"
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
                Row {
                  spacing: Style.space(8)
                  Repeater {
                    model: ["off", "on"]
                    Rectangle {
                      required property var modelData
                      readonly property bool active: root.draftAlertPrecip === modelData
                      height: Style.space(28)
                      width: pcLabel.implicitWidth + Style.space(20)
                      radius: Style.cornerRadius
                      color: active ? (root.bar ? root.bar.foreground : "#cacccc") : "transparent"
                      border.width: active ? 0 : 1
                      border.color: root.bar ? root.bar.foreground : "#cacccc"
                      Text {
                        id: pcLabel
                        anchors.centerIn: parent
                        text: modelData
                        color: parent.active
                          ? (root.bar ? root.bar.background : "#101315")
                          : (root.bar ? root.bar.foreground : "#cacccc")
                        font.family: root.bar ? root.bar.fontFamily : "monospace"
                        font.pixelSize: Style.font.bodySmall
                      }
                      MouseArea {
                        anchors.fill: parent
                        enabled: !root.savingSettings
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.draftAlertPrecip = modelData
                      }
                    }
                  }
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(12)
                Text {
                  width: Style.space(200)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "NWS ALERTS (US)"
                  color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "gray"
                  font.family: root.bar ? root.bar.fontFamily : "monospace"
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
                Row {
                  spacing: Style.space(8)
                  Repeater {
                    model: ["off", "on"]
                    Rectangle {
                      required property var modelData
                      readonly property bool active: root.draftAlertNws === modelData
                      height: Style.space(28)
                      width: nwLabel.implicitWidth + Style.space(20)
                      radius: Style.cornerRadius
                      color: active ? (root.bar ? root.bar.foreground : "#cacccc") : "transparent"
                      border.width: active ? 0 : 1
                      border.color: root.bar ? root.bar.foreground : "#cacccc"
                      Text {
                        id: nwLabel
                        anchors.centerIn: parent
                        text: modelData
                        color: parent.active
                          ? (root.bar ? root.bar.background : "#101315")
                          : (root.bar ? root.bar.foreground : "#cacccc")
                        font.family: root.bar ? root.bar.fontFamily : "monospace"
                        font.pixelSize: Style.font.bodySmall
                      }
                      MouseArea {
                        anchors.fill: parent
                        enabled: !root.savingSettings
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.draftAlertNws = modelData
                      }
                    }
                  }
                }
              }

              // Cumulative level: each stop includes the ones to its left.
              Row {
                id: nwsLevelOuter
                width: parent.width
                spacing: Style.space(12)
                opacity: root.draftAlertNws === "on" ? 1 : 0.4
                readonly property int selRank: root.draftAlertNwsLevel === "advisories" ? 2
                  : root.draftAlertNwsLevel === "watches" ? 1 : 0
                Text {
                  width: Style.space(64)
                  anchors.verticalCenter: parent.verticalCenter
                  text: " · level"
                  color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "gray"
                  font.family: root.bar ? root.bar.fontFamily : "monospace"
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
                Row {
                  id: nwsLevelRow
                  spacing: Style.space(8)
                  Repeater {
                    model: [
                      { key: "warnings",   label: "Warnings",   rank: 0 },
                      { key: "watches",    label: "Watches",    rank: 1 },
                      { key: "advisories", label: "Advisories", rank: 2 }
                    ]
                    Rectangle {
                      required property var modelData
                      readonly property bool active: modelData.rank <= nwsLevelOuter.selRank
                      height: Style.space(28)
                      width: nwsLvlLabel.implicitWidth + Style.space(20)
                      radius: Style.cornerRadius
                      color: active ? (root.bar ? root.bar.foreground : "#cacccc") : "transparent"
                      border.width: active ? 0 : 1
                      border.color: root.bar ? root.bar.foreground : "#cacccc"
                      Text {
                        id: nwsLvlLabel
                        anchors.centerIn: parent
                        text: modelData.label
                        color: parent.active
                          ? (root.bar ? root.bar.background : "#101315")
                          : (root.bar ? root.bar.foreground : "#cacccc")
                        font.family: root.bar ? root.bar.fontFamily : "monospace"
                        font.pixelSize: Style.font.bodySmall
                      }
                      MouseArea {
                        anchors.fill: parent
                        enabled: !root.savingSettings && root.draftAlertNws === "on"
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.draftAlertNwsLevel = modelData.key
                      }
                    }
                  }
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(12)
                Text {
                  width: Style.space(200)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "DESKTOP NOTIFICATION"
                  color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "gray"
                  font.family: root.bar ? root.bar.fontFamily : "monospace"
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
                Row {
                  spacing: Style.space(8)
                  Repeater {
                    model: ["off", "on"]
                    Rectangle {
                      required property var modelData
                      readonly property bool active: root.draftAlertNotify === modelData
                      height: Style.space(28)
                      width: ntLabel.implicitWidth + Style.space(20)
                      radius: Style.cornerRadius
                      color: active ? (root.bar ? root.bar.foreground : "#cacccc") : "transparent"
                      border.width: active ? 0 : 1
                      border.color: root.bar ? root.bar.foreground : "#cacccc"
                      Text {
                        id: ntLabel
                        anchors.centerIn: parent
                        text: modelData
                        color: parent.active
                          ? (root.bar ? root.bar.background : "#101315")
                          : (root.bar ? root.bar.foreground : "#cacccc")
                        font.family: root.bar ? root.bar.fontFamily : "monospace"
                        font.pixelSize: Style.font.bodySmall
                      }
                      MouseArea {
                        anchors.fill: parent
                        enabled: !root.savingSettings
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.draftAlertNotify = modelData
                      }
                    }
                  }
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(28)

                Column {
                  spacing: Style.space(4)
                  Text {
                    text: "LIGHTNING MAX DIST  (0 = any)"
                    color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "gray"
                    font.family: root.bar ? root.bar.fontFamily : "monospace"
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                  }
                  TextField {
                    width: Style.space(80)
                    enabled: !root.savingSettings
                    text: root.draftAlertMaxDist
                    foreground: root.bar ? root.bar.foreground : "white"
                    font.family: root.bar ? root.bar.fontFamily : "monospace"
                    inputMethodHints: Qt.ImhDigitsOnly
                    validator: IntValidator { bottom: 0; top: 300 }
                    onTextChanged: root.draftAlertMaxDist = text
                    Keys.onPressed: function(event) {
                      if (event.key === Qt.Key_Escape) { root.cancelEditingSettings(); event.accepted = true }
                      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.saveSettings(); event.accepted = true }
                    }
                  }
                }

                Column {
                  spacing: Style.space(4)
                  Text {
                    text: "ALL ALERTS · POLL SEC"
                    color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "gray"
                    font.family: root.bar ? root.bar.fontFamily : "monospace"
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                  }
                  TextField {
                    width: Style.space(80)
                    enabled: !root.savingSettings
                    text: root.draftAlertPoll
                    foreground: root.bar ? root.bar.foreground : "white"
                    font.family: root.bar ? root.bar.fontFamily : "monospace"
                    inputMethodHints: Qt.ImhDigitsOnly
                    validator: IntValidator { bottom: 60; top: 3600 }
                    onTextChanged: root.draftAlertPoll = text
                    Keys.onPressed: function(event) {
                      if (event.key === Qt.Key_Escape) { root.cancelEditingSettings(); event.accepted = true }
                      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.saveSettings(); event.accepted = true }
                    }
                  }
                }
              }

              Column {
                spacing: Style.space(4)
                opacity: root.draftAlertNotify === "on" ? 1 : 0.4
                Text {
                  text: "NOTIFICATION AUTO-DISMISS  (SEC, 0 = OFF)"
                  color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "gray"
                  font.family: root.bar ? root.bar.fontFamily : "monospace"
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
                TextField {
                  width: Style.space(80)
                  enabled: !root.savingSettings && root.draftAlertNotify === "on"
                  text: root.draftNotifyTimeout
                  foreground: root.bar ? root.bar.foreground : "white"
                  font.family: root.bar ? root.bar.fontFamily : "monospace"
                  inputMethodHints: Qt.ImhDigitsOnly
                  validator: IntValidator { bottom: 0; top: 86400 }
                  onTextChanged: root.draftNotifyTimeout = text
                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape) { root.cancelEditingSettings(); event.accepted = true }
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.saveSettings(); event.accepted = true }
                  }
                }
              }

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "One background poll drives all three — lightning, rain/snow, and NWS "
                  + "alerts (min 60 s). Each can lag by up to one interval. Auto-dismiss "
                  + "clears the notification after N seconds; critical alerts (severe "
                  + "storms, tornado) may stay pinned regardless of it."
                color: root.bar ? Qt.darker(root.bar.foreground, 1.6) : "gray"
                font.family: root.bar ? root.bar.fontFamily : "monospace"
                font.pixelSize: Style.font.caption
                font.italic: true
              }

              // -- Sounds: path override + a test button per alert type.
              //    Blank path = the sound bundled with the plugin.
              Text {
                text: "SOUNDS  (blank = built-in)"
                color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "gray"
                font.family: root.bar ? root.bar.fontFamily : "monospace"
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }

              Repeater {
                model: [
                  { label: "LIGHTNING", kind: "lightning" },
                  { label: "RAIN",      kind: "precip" },
                  { label: "SNOW",      kind: "snow" },
                  { label: "STORM",     kind: "nws" }
                ]

                Row {
                  id: soundRow
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(8)

                  Text {
                    width: Style.space(66)
                    anchors.verticalCenter: parent.verticalCenter
                    text: soundRow.modelData.label
                    color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "gray"
                    font.family: root.bar ? root.bar.fontFamily : "monospace"
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                  }

                  TextField {
                    width: parent.width - Style.space(66) - Style.space(32) - Style.space(32) - Style.space(24)
                    anchors.verticalCenter: parent.verticalCenter
                    enabled: !root.savingSettings
                    placeholderText: "built-in"
                    text: root.draftSoundFor(soundRow.modelData.kind)
                    foreground: root.bar ? root.bar.foreground : "white"
                    font.family: root.bar ? root.bar.fontFamily : "monospace"
                    onTextChanged: root.setDraftSound(soundRow.modelData.kind, text)
                    Keys.onPressed: function(event) {
                      if (event.key === Qt.Key_Escape) { root.cancelEditingSettings(); event.accepted = true }
                      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.saveSettings(); event.accepted = true }
                    }
                  }

                  // ▶ test
                  Rectangle {
                    width: Style.space(32); height: Style.space(28)
                    anchors.verticalCenter: parent.verticalCenter
                    radius: Style.cornerRadius
                    color: "transparent"
                    border.width: 1
                    border.color: root.bar ? root.bar.foreground : "#cacccc"
                    Text {
                      anchors.centerIn: parent
                      text: String.fromCharCode(0x25b6)
                      color: root.bar ? root.bar.foreground : "#cacccc"
                      font.family: root.bar ? root.bar.fontFamily : "monospace"
                      font.pixelSize: Style.font.caption
                    }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.testAlertSound(soundRow.modelData.kind, root.draftSoundFor(soundRow.modelData.kind))
                    }
                  }

                  // browse (folder)
                  Rectangle {
                    width: Style.space(32); height: Style.space(28)
                    anchors.verticalCenter: parent.verticalCenter
                    radius: Style.cornerRadius
                    readonly property bool active: root.browsingSound && root.browseKind === soundRow.modelData.kind
                    color: active ? (root.bar ? root.bar.foreground : "#cacccc") : "transparent"
                    border.width: active ? 0 : 1
                    border.color: root.bar ? root.bar.foreground : "#cacccc"
                    Text {
                      anchors.centerIn: parent
                      text: String.fromCharCode(0xf07b)   // nf folder
                      color: parent.active ? (root.bar ? root.bar.background : "#101315")
                        : (root.bar ? root.bar.foreground : "#cacccc")
                      font.family: root.bar ? root.bar.fontFamily : "monospace"
                      font.pixelSize: Style.font.caption
                    }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.browsingSound && root.browseKind === soundRow.modelData.kind
                        ? root.closeSoundBrowse()
                        : root.openSoundBrowse(soundRow.modelData.kind)
                    }
                  }
                }
              }

              // -- In-panel file browser (opened by a row's folder button)
              Column {
                visible: root.browsingSound
                width: parent.width
                spacing: Style.space(6)

                Row {
                  width: parent.width
                  spacing: Style.space(8)
                  Text {
                    width: Style.space(90)
                    anchors.verticalCenter: parent.verticalCenter
                    text: "BROWSE"
                    color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "gray"
                    font.family: root.bar ? root.bar.fontFamily : "monospace"
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                  }
                  Text {
                    width: parent.width - Style.space(90) - Style.space(24) - Style.space(16)
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.browseDir
                    elide: Text.ElideLeft
                    color: root.bar ? Qt.darker(root.bar.foreground, 1.6) : "gray"
                    font.family: root.bar ? root.bar.fontFamily : "monospace"
                    font.pixelSize: Style.font.caption
                  }
                  Rectangle {
                    width: Style.space(24); height: Style.space(24)
                    anchors.verticalCenter: parent.verticalCenter
                    radius: Style.cornerRadius
                    color: "transparent"
                    border.width: 1
                    border.color: root.bar ? root.bar.foreground : "#cacccc"
                    Text {
                      anchors.centerIn: parent
                      text: String.fromCharCode(0x00d7)
                      color: root.bar ? root.bar.foreground : "#cacccc"
                      font.family: root.bar ? root.bar.fontFamily : "monospace"
                      font.pixelSize: Style.font.bodySmall
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.closeSoundBrowse() }
                  }
                }

                Row {
                  spacing: Style.space(6)
                  Repeater {
                    model: [ { label: "~", path: root.homeDir },
                             { label: "/usr/share/sounds", path: "/usr/share/sounds" } ]
                    Rectangle {
                      required property var modelData
                      height: Style.space(24)
                      width: jumpLabel.implicitWidth + Style.space(16)
                      radius: Style.cornerRadius
                      color: "transparent"
                      border.width: 1
                      border.color: root.bar ? Qt.darker(root.bar.foreground, 1.7) : "gray"
                      Text {
                        id: jumpLabel
                        anchors.centerIn: parent
                        text: modelData.label
                        color: root.bar ? root.bar.foreground : "#cacccc"
                        font.family: root.bar ? root.bar.fontFamily : "monospace"
                        font.pixelSize: Style.font.caption
                      }
                      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.listSoundDir(modelData.path) }
                    }
                  }
                }

                Rectangle {
                  width: parent.width
                  height: Style.space(190)
                  radius: Style.cornerRadius
                  color: "transparent"
                  border.width: 1
                  border.color: root.bar ? Qt.darker(root.bar.foreground, 1.7) : "gray"
                  clip: true

                  Flickable {
                    anchors.fill: parent
                    anchors.margins: Style.space(4)
                    contentWidth: width
                    contentHeight: browseCol.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    interactive: contentHeight > height

                    Column {
                      id: browseCol
                      width: parent.width

                      Text {
                        visible: root.browseEntries.length === 0
                        text: "  (nothing here)"
                        color: root.bar ? Qt.darker(root.bar.foreground, 1.7) : "gray"
                        font.family: root.bar ? root.bar.fontFamily : "monospace"
                        font.pixelSize: Style.font.caption
                        font.italic: true
                      }

                      Repeater {
                        model: root.browseEntries
                        Rectangle {
                          required property var modelData
                          width: browseCol.width
                          height: Style.space(24)
                          color: entryArea.containsMouse
                            ? (root.bar ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "#222")
                            : "transparent"
                          Text {
                            anchors.left: parent.left
                            anchors.leftMargin: Style.space(6)
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - Style.space(12)
                            elide: Text.ElideRight
                            text: modelData.type === "up" ? ".."
                              : modelData.type === "dir" ? (modelData.name + "/")
                              : modelData.name
                            color: modelData.type === "file"
                              ? (root.bar ? root.bar.foreground : "#cacccc")
                              : (root.bar ? Qt.darker(root.bar.foreground, 1.35) : "gray")
                            font.family: root.bar ? root.bar.fontFamily : "monospace"
                            font.pixelSize: Style.font.caption
                          }
                          MouseArea {
                            id: entryArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.browsePick(modelData)
                          }
                        }
                      }
                    }
                  }
                }

                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  text: "Tap a folder to open it, an audio file to pick it. Filters to .wav .ogg .oga .flac .opus."
                  color: root.bar ? Qt.darker(root.bar.foreground, 1.7) : "gray"
                  font.family: root.bar ? root.bar.fontFamily : "monospace"
                  font.pixelSize: Style.font.caption
                  font.italic: true
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
                color: root.bar ? root.bar.foreground : "#cacccc"
                opacity: root.savingSettings ? 0.6 : 1
                Text {
                  id: saveLabel
                  anchors.centerIn: parent
                  text: root.savingSettings ? "Saving..." : "Save"
                  color: root.bar ? root.bar.background : "#101315"
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
                border.color: root.bar ? root.bar.foreground : "#cacccc"
                Text {
                  id: cancelLabel
                  anchors.centerIn: parent
                  text: "Cancel"
                  color: root.bar ? root.bar.foreground : "#cacccc"
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
    }
  }
}
