import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Headless alert service for the Tempest Weather plugin (AlertService.qml).
//
// The bar widget (BarWidget.qml / Panel.qml) shows the station's conditions on
// a leisurely refresh. This service runs alongside it on a much shorter poll
// and makes an audible sound (plus an optional desktop notification) when the
// station reports a lightning strike or the start of rain/snow.
//
// It is mounted automatically whenever the plugin is enabled (the shell loads
// any enabled plugin that declares kind "service"). It shares Model.js with
// the widget and reads the same credentials out of the merged shell.json.
//
// All alerts are OFF by default; with nothing enabled the service does not
// poll at all.
Item {
  id: root

  // Injected by the shell's service loader.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.dreed47.tempest-weather"

  // ---- Configuration ----------------------------------------------------
  //
  // The service is not placed in the bar layout, so it has no settings object
  // of its own. It reads the widget's entry straight out of the merged
  // shell.json (the same token / station / units the popup uses, plus the
  // alert keys). One stable source on purpose: an earlier version also took a
  // value pushed in from the widget, and the two races made canPoll flicker.

  readonly property var cfg: {
    var sc = shell ? shell.shellConfig : null
    if (!sc) return null
    try {
      if (sc.bar && sc.bar.layout) {
        var secs = ["left", "center", "right"]
        for (var s = 0; s < secs.length; s++) {
          var arr = sc.bar.layout[secs[s]] || []
          for (var i = 0; i < arr.length; i++)
            if (arr[i] && String(arr[i].id) === root.pluginId) return arr[i]
        }
      }
      var plugs = sc.plugins || []
      for (var j = 0; j < plugs.length; j++)
        if (plugs[j] && String(plugs[j].id) === root.pluginId) return plugs[j]
    } catch (e) {}
    return null
  }

  function cval(key, dflt) {
    var c = root.cfg
    if (c && c[key] !== undefined && c[key] !== null && String(c[key]) !== "") return c[key]
    return dflt
  }

  readonly property string token: {
    var v = String(cval("token", "")).replace(/^\s+|\s+$/g, "")
    return v !== "" ? v : String(Quickshell.env("TEMPEST_TOKEN") || "").replace(/^\s+|\s+$/g, "")
  }
  readonly property string configuredStationId: {
    var v = String(cval("stationId", "")).replace(/^\s+|\s+$/g, "")
    return v !== "" ? v : String(Quickshell.env("TEMPEST_STATION_ID") || "").replace(/^\s+|\s+$/g, "")
  }
  property string discoveredStationId: ""
  readonly property string stationId: configuredStationId !== "" ? configuredStationId : discoveredStationId

  readonly property string units: Model.normalizedUnits(cval("units", "metric"))
  readonly property var unitParams: Model.apiUnitParams(units)
  readonly property string distanceLabel: units === "imperial" ? "mi" : "km"

  readonly property bool alertLightning: String(cval("alertLightning", "off")).toLowerCase() === "on"
  readonly property real alertLightningMaxDistance: parseFloat(String(cval("alertLightningMaxDistance", "0"))) || 0
  readonly property bool alertPrecipStart: String(cval("alertPrecipStart", "off")).toLowerCase() === "on"
  readonly property bool alertNotify: String(cval("alertNotify", "on")).toLowerCase() === "on"
  readonly property int pollSeconds: Math.max(60, parseInt(String(cval("alertPollSeconds", "90")), 10) || 90)
  readonly property string lightningSound: String(cval("alertLightningSound", "")).replace(/^\s+|\s+$/g, "")
  readonly property string precipSound: String(cval("alertPrecipSound", "")).replace(/^\s+|\s+$/g, "")
  readonly property string snowSound: String(cval("alertSnowSound", "")).replace(/^\s+|\s+$/g, "")

  // NWS (US National Weather Service) area alerts — a separate feed from the
  // station's own sensors. Off by default; needs the station coordinates,
  // which come free in the better_forecast response.
  readonly property bool alertNws: String(cval("alertNws", "off")).toLowerCase() === "on"
  readonly property string nwsSound: String(cval("alertNwsSound", "")).replace(/^\s+|\s+$/g, "")
  readonly property string nwsMinSeverity: String(cval("alertNwsMinSeverity", "Severe"))

  readonly property bool anyAlertEnabled: alertLightning || alertPrecipStart || alertNws
  readonly property bool canPoll: anyAlertEnabled && token !== "" && stationId !== ""

  // Default alert sounds shipped with the plugin. Each is the matching
  // freedesktop sound with ~1s of leading silence, so it is still audible on
  // an HDMI/receiver output that idle-suspends and takes a moment to wake.
  readonly property string pluginDir: decodeURIComponent(
    Qt.resolvedUrl(".").toString().replace(/^file:\/\//, ""))
  readonly property string defaultLightningSound: pluginDir + "sounds/lightning.ogg"
  readonly property string defaultRainSound: pluginDir + "sounds/rain.ogg"
  readonly property string defaultSnowSound: pluginDir + "sounds/snow.ogg"
  readonly property string defaultNwsSound: pluginDir + "sounds/nws.ogg"

  readonly property string requestUrl: "https://swd.weatherflow.com/swd/rest/better_forecast"
    + "?station_id=" + encodeURIComponent(stationId)
    + "&token=" + encodeURIComponent(token)
    + "&units_temp=" + unitParams.temp
    + "&units_wind=" + unitParams.wind
    + "&units_pressure=" + unitParams.pressure
    + "&units_distance=" + unitParams.distance
    + "&units_precip=" + unitParams.precip

  // ---- Runtime alert state -------------------------------------------------

  // Epoch seconds at which this service instance came up. Strikes older than
  // this are pre-existing history and never alerted on, so a shell restart
  // during a storm does not replay it.
  readonly property double startedAtEpoch: Math.floor(Date.now() / 1000)

  property int lastLightningEpoch: 0
  property string lastPrecipDay: ""
  property var lastReport: null
  property double lastSoundMs: 0

  // Station coordinates, filled from the better_forecast response, used for the
  // NWS alerts query.
  property real lat: 0
  property real lon: 0
  readonly property bool haveCoords: lat !== 0 && lon !== 0
  readonly property string nwsUrl: haveCoords
    ? ("https://api.weather.gov/alerts/active?point=" + lat + "," + lon) : ""

  // NWS alert ids already accounted for, so each alert sounds once. `baselined`
  // means the first post-startup poll has run: alerts active before that are
  // adopted silently, so a restart mid-warning is not a fresh alarm.
  property var seenNwsIds: ({})
  property bool nwsBaselined: false
  property bool nwsActive: false
  // Qualifying active alerts (each is a GeoJSON `properties` object), severity
  // first. The popup reads this to show a summary; a link there opens the
  // weather.gov point page built from lat/lon.
  property var nwsAlerts: []

  onAlertNwsChanged: {
    if (alertNws) { seenNwsIds = ({}); nwsBaselined = false }
    else { nwsActive = false; nwsAlerts = [] }
  }

  // True for a window after the most recent strike, so the bar pill can show a
  // marker. Cleared when lightningClear fires.
  readonly property bool lightningActive: lightningClear.running

  // Test hook: set true to ignore the "predates startup" gate, so a strike
  // already in the API response fires once. Leave false in normal use.
  readonly property bool debugForce: false

  // ---- Station discovery (mirrors Panel.qml) ---------------------------

  function maybeDiscoverStation() {
    if (token === "" || configuredStationId !== "" || discoveredStationId !== ""
        || stationsProc.running || !anyAlertEnabled) return
    stationsProc.running = true
  }

  onTokenChanged: { discoveredStationId = ""; Qt.callLater(maybeDiscoverStation) }
  onAnyAlertEnabledChanged: Qt.callLater(maybeDiscoverStation)

  Process {
    id: stationsProc
    command: ["curl", "-fsS", "--max-time", "10",
      "https://swd.weatherflow.com/swd/rest/stations?token=" + encodeURIComponent(root.token)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || "").replace(/^\s+|\s+$/g, ""))
          if (d && d.stations && d.stations.length > 0
              && d.stations[0].station_id !== undefined && d.stations[0].station_id !== null)
            root.discoveredStationId = String(d.stations[0].station_id)
        } catch (e) {}
      }
    }
  }

  // ---- Poll + evaluate ------------------------------------------------

  Process {
    id: pollProc
    command: ["curl", "-fsS", "--max-time", "10", root.requestUrl]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").replace(/^\s+|\s+$/g, "")
        if (raw === "") return
        try {
          var parsed = JSON.parse(raw)
          if (parsed && parsed.current_conditions) root.evaluate(parsed)
        } catch (e) {}
      }
    }
  }

  function poll() {
    maybeDiscoverStation()
    if (!canPoll || pollProc.running) return
    pollProc.running = true
  }

  function pollNws() {
    if (!alertNws || !haveCoords || nwsProc.running) return
    nwsProc.running = true
  }

  function evaluate(parsed) {
    var cur = parsed.current_conditions

    var la = parseFloat(parsed.latitude), lo = parseFloat(parsed.longitude)
    if (!isNaN(la) && !isNaN(lo) && la !== 0 && lo !== 0) { root.lat = la; root.lon = lo }

    var L = Model.detectLightning(cur, {
      enabled: root.alertLightning,
      maxDistance: root.alertLightningMaxDistance,
      sinceEpoch: root.debugForce ? 0 : root.startedAtEpoch,
      lastEpoch: root.lastLightningEpoch
    })
    // Advance the marker even for a strike we did not alert on (one that
    // predates startup), so it is not re-examined every poll.
    if (L.epoch > root.lastLightningEpoch) root.lastLightningEpoch = L.epoch
    if (L.fire) fireLightning(L)

    var epoch = parseInt(String(cur.time || ""), 10)
    if (isNaN(epoch) || epoch <= 0) epoch = Math.floor(Date.now() / 1000)
    var day = Qt.formatDate(new Date(epoch * 1000), "yyyy-MM-dd")
    var P = Model.detectPrecipStart(root.lastReport ? root.lastReport.current_conditions : null, cur, {
      enabled: root.alertPrecipStart,
      currentDay: day,
      lastFiredDay: root.lastPrecipDay
    })
    if (P.fire) {
      root.lastPrecipDay = day
      firePrecip(P)
    }

    root.lastReport = parsed
    if (root.alertNws && root.haveCoords) Qt.callLater(root.pollNws)
  }

  // ---- NWS area alerts ----------------------------------------------------

  Process {
    id: nwsProc
    command: ["curl", "-fsS", "--max-time", "15",
      "-H", "User-Agent: tempest-weather Omarchy plugin (github.com/dreed47/tempest-weather)",
      "-H", "Accept: application/geo+json",
      root.nwsUrl]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").replace(/^\s+|\s+$/g, "")
        if (raw === "") return
        try {
          var d = JSON.parse(raw)
          if (d && Array.isArray(d.features)) root.evaluateNws(d.features)
        } catch (e) {}
      }
    }
  }

  function evaluateNws(features) {
    var nextSeen = ({})
    var newOnes = []
    var current = []
    for (var i = 0; i < features.length; i++) {
      var p = features[i] ? features[i].properties : null
      if (!Model.nwsQualifies(p, root.nwsMinSeverity)) continue
      current.push(p)
      var id = String(p.id || "")
      if (id === "") continue
      nextSeen[id] = true
      if (!root.seenNwsIds[id]) newOnes.push(p)
    }
    current.sort(function(a, b) {
      return (Model.nwsSeverityRank(b) - Model.nwsSeverityRank(a))
    })
    root.nwsActive = current.length > 0
    root.nwsAlerts = current   // for the popup summary

    if (!root.nwsBaselined && !root.debugForce) {
      root.seenNwsIds = nextSeen   // adopt what is already active, silently
      root.nwsBaselined = true
      return
    }
    root.seenNwsIds = nextSeen
    for (var j = 0; j < newOnes.length; j++) fireNws(newOnes[j])
  }

  function fireNws(p) {
    var sev = String(p.severity || "").toLowerCase()
    var crit = (sev === "extreme" || sev === "severe")
    playSound(root.nwsSound !== "" ? root.nwsSound : root.defaultNwsSound)
    notify(
      Model.nwsEventLabel(p),
      String(p.headline || p.areaDesc || "Issued by the US National Weather Service"),
      crit ? "critical" : "normal",
      String.fromCharCode(0xf071))   // nf triangle-exclamation
  }

  // ---- Alert output -------------------------------------------------------

  Process { id: soundProc }

  function playSound(path) {
    if (path === "" || soundProc.running) return
    var now = Date.now()
    if (now - root.lastSoundMs < 10000) return   // debounce back-to-back sounds
    root.lastSoundMs = now
    soundProc.command = ["pw-play", path]
    soundProc.running = true
  }

  property var notifyQueue: []
  Process {
    id: notifyProc
    onExited: root.runNextNotify()
  }
  function notify(headline, body, urgency, glyph) {
    if (!root.alertNotify) return
    var cmd = ["omarchy-notification-send", "-u", String(urgency || "normal")]
    if (glyph && glyph !== "") { cmd.push("-g"); cmd.push(String(glyph)) }
    cmd.push(String(headline))
    if (body && body !== "") cmd.push(String(body))
    notifyQueue.push(cmd)
    runNextNotify()
  }
  function runNextNotify() {
    if (notifyProc.running || notifyQueue.length === 0) return
    notifyProc.command = notifyQueue.shift()
    notifyProc.running = true
  }

  function fireLightning(L) {
    lightningClear.restart()
    var dstr = (L.distance !== null && !isNaN(L.distance))
      ? (Model.roundedTo(L.distance, 0) + " " + root.distanceLabel) : ""
    playSound(root.lightningSound !== "" ? root.lightningSound : root.defaultLightningSound)
    notify(
      "Lightning" + (dstr !== "" ? " " + dstr : ""),
      "Strike detected by your Tempest station"
        + (L.count > 1 ? " (" + L.count + " in the last hour)" : ""),
      "critical",
      String.fromCharCode(0xe31d))   // wi-thunderstorm
  }

  function firePrecip(P) {
    var snow = P.kind === "snow"
    var snd = (snow && root.snowSound !== "") ? root.snowSound
      : (root.precipSound !== "" ? root.precipSound
        : (snow ? root.defaultSnowSound : root.defaultRainSound))
    playSound(snd)
    var word = snow ? "Snow" : (P.kind === "sleet" ? "Sleet" : "Rain")
    notify(word + " started", "Precipitation detected by your Tempest station",
      "normal", Model.iconForTempest(snow ? "snow" : "rainy"))
  }

  // ---- Timers -------------------------------------------------------------

  Timer {
    id: pollTimer
    interval: root.pollSeconds * 1000
    running: root.canPoll
    repeat: true
    triggeredOnStart: true
    onTriggered: { root.poll(); root.pollNws() }
  }

  // Re-poll promptly when alerts are switched on or credentials change.
  onCanPollChanged: if (canPoll) Qt.callLater(root.poll)
  onRequestUrlChanged: if (canPoll) Qt.callLater(root.poll)
  onNwsUrlChanged: if (alertNws && haveCoords) Qt.callLater(root.pollNws)

  Timer {
    id: lightningClear
    interval: 20 * 60 * 1000   // "lightning active" marker lingers 20 min
    repeat: false
  }

  // ---- Real-time seam ---------------------------------------------------
  //
  // A follow-up can add instant lightning/precip events by feeding this same
  // evaluate()/fire path from the Tempest hub's local UDP broadcast (port
  // 50222, `evt_strike` / `evt_precip`) via a small sidecar Process, or the
  // cloud WebSocket. The poll above stays as the always-available fallback.
}
