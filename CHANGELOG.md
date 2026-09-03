# Changelog

## Unreleased — alerts (alerts-sandbox branch)

- New headless alert service (`AlertService.qml`, manifest kind `service`). It
  runs whenever the plugin is enabled, polls the station on its own short
  interval, and on a lightning strike or the start of rain/snow plays a sound
  (`pw-play`) and, by default, raises a desktop notification.
- All alerts are off by default. New settings: `alertLightning`,
  `alertLightningMaxDistance`, `alertPrecipStart`, `alertNotify`,
  `alertPollSeconds`, `alertLightningSound` / `alertPrecipSound` /
  `alertSnowSound`. The settings form gains an ALERTS section: on/off switches,
  max distance, poll interval, and a SOUNDS block with, per alert type, a path
  field, a **test** button, and a folder button that opens an in-panel file
  browser (folders + `.wav`/`.ogg`/`.oga`/`.flac`/`.opus` files, tap to
  descend or pick). A native file dialog can't be used — it opens behind the
  overlay-layer popup — so the browser is rendered inside the card.
- Alert sounds ship with the plugin (`sounds/*.ogg`): the matching freedesktop
  sound with ~1 s of leading silence, so the alert is still audible on an
  HDMI / AV-receiver output that idle-suspends and takes a moment to wake.
  Leaving a sound field blank uses the bundled default.
- The bar pill shows a bolt marker for 20 minutes while a lightning alert is
  active.
- Third alert source: US National Weather Service area alerts
  (`api.weather.gov/alerts/active`, no key). Off by default; toggled with
  `alertNws`, its own bundled sound (`sounds/nws.ogg`, overridable via
  `alertNwsSound` or the form's SOUNDS block). Fires on a newly issued alert at
  severity Severe/Extreme (`alertNwsMinSeverity` widens/narrows this); alerts
  already active when the service starts are adopted silently. Station
  coordinates come from the forecast response — no extra config. The pill shows
  a warning triangle while an NWS alert is active, and the popup shows a banner
  with the event, the NWS headline, an inline **full text** expander, and a
  link to the weather.gov point page (radar + official text). `AlertService`
  exposes `nwsAlerts`; `Model.js` gains `nwsQualifies` / `nwsEventLabel` /
  `nwsSeverityRank` / `nwsSummary`.
- `Model.js` gains pure helpers `iconWet`, `precipKind`, `detectLightning`,
  `detectPrecipStart`.
- Not yet released to the marketplace: this rides on the `alerts-sandbox`
  branch until the base plugin is accepted and the alerts prove out on a real
  storm.

## 0.4.1

- Fixed the bar pill overlapping the widget next to it in the bar's center
  section. The pill now uses `WidgetButton` (a text label sized to its
  content) instead of `BarIconButton` (an icon-only slot of fixed width), so
  the glyph-plus-temperature label no longer paints outside the button box.

## 0.4.0

- Popup header: `● <STATION NAME> — LIVE · UPDATED <n>m ago`, built from
  `location_name` and the reading timestamp. Makes it obvious the numbers are
  live data from the user's own station, and the age advances once a minute
  while the popup is open.
- Bar-pill tooltip now names the station ("<name> - your Tempest station").
- `Model.relativeAge()` helper for the freshness string.

## 0.3.0

- Station ID is now optional: with only a token set, the station is looked up
  from `GET /stations` (the first station on the account). Set a station ID
  only for a multi-station account.
- The pill stays visible before setup (neutral cloud glyph) so a fresh install
  is discoverable; clicking it opens the popup with setup guidance.
- Moved the gear to its own strip so the current condition no longer sits under
  it; the condition text now reads under the temperature.

## 0.2.0

- Inline settings form: click the gear in the popup to edit station ID, API
  token, units, and refresh interval. Save persists each field to the widget's
  `shell.json` entry via `omarchy-bar set` (no hand-editing needed).
- Popup now anchors under the pill instead of centering on the bar.

## 0.1.0

- Initial release.
- Bar pill: current condition glyph + temperature from a WeatherFlow Tempest
  station via the Better Forecast API.
- Detail popup: feels-like, wind + direction, humidity, sea-level pressure and
  trend, UV, dew point, and a three-day forecast.
- Credentials from the widget's `shell.json` entry or `$TEMPEST_STATION_ID` /
  `$TEMPEST_TOKEN`.
- Settings: `units` (metric/imperial), `refreshMinutes`.
- Left click toggles the popup, middle click refreshes, right click sends a
  desktop notification with the full summary.
