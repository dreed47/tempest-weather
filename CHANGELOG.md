# Changelog

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
