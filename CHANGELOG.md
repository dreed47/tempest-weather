# Changelog

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
