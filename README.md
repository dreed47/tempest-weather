# Tempest Weather

An Omarchy shell bar widget that shows conditions from **your own
[WeatherFlow Tempest](https://tempest.earth/) weather station** instead of a
modelled forecast for your city.

The pill shows the current condition glyph and temperature. Clicking it opens a
popup with feels-like, wind, humidity, sea-level pressure and its trend, UV,
dew point, and a three-day forecast — all pulled straight from the station
owner's [Better Forecast API](https://weatherflow.github.io/Tempest/api/), so
the readings match the Tempest app.

![Tempest Weather popup](preview.png)

Credentials, units, and refresh interval are set from a form in the popup — no
config file editing required:

![Settings form](settings.png)

## Requirements

- Omarchy with `omarchy-shell` (the Quickshell bar).
- `curl` on `PATH` (ships with Omarchy).
- A Tempest personal access token from
  <https://tempestwx.com/settings/tokens>. That's all — the token is
  account-scoped, so the station is detected automatically. A station ID is
  only needed if your account has more than one station.

On first run, before a token is set, the pill still shows (a neutral cloud);
click it and the popup explains setup and opens the settings form.

## Install

```bash
omarchy plugin add https://github.com/dreed47/tempest-weather.git
omarchy plugin enable io.github.dreed47.tempest-weather right
```

(The clone lands in `~/.config/omarchy/plugins/io.github.dreed47.tempest-weather/`,
named after the manifest `id` regardless of the repo name.)

The plugin lands disabled so you can review the code first; `enable` mounts it
in the bar's right section. Move it with `omarchy bar move`.

## Configuration

The widget needs your station ID and token. It reads them, in order of
precedence:

1. The widget's own entry in `~/.config/omarchy/shell.json`.
2. The environment variables `TEMPEST_STATION_ID` and `TEMPEST_TOKEN` in the
   shell's environment.

### Option A — the settings form (easiest)

Open the popup and click the **gear** (top-right). Paste your token, pick
units, set the refresh interval, and **Save**. Leave **Station ID** blank
unless your account has more than one station — it is auto-detected. Each
field is written to the widget's `shell.json` entry with `omarchy-bar set`
and the pill reloads immediately; a blank field falls back to the matching
environment variable.

### Option B — edit shell.json directly

Edit the widget's layout entry in `~/.config/omarchy/shell.json`:

```json
{
  "id": "io.github.dreed47.tempest-weather",
  "token": "your-tempest-token",
  "units": "metric",
  "refreshMinutes": 10
}
```

Add `"stationId": "12345"` only for a multi-station account.

The shell hot-reloads `shell.json`, so the pill updates within a few seconds.

> `shell.json` is a plaintext file in your home directory. If you would rather
> not keep the token there, use Option B.

### Option C — environment variables

Export the credentials where the shell can see them — for a uwsm/Hyprland
session, `~/.config/environment.d/tempest.conf`:

```
TEMPEST_STATION_ID=12345
TEMPEST_TOKEN=your-tempest-token
```

Log out and back in (or `systemctl --user import-environment` then restart the
shell) so `omarchy-shell` picks them up. Leave `stationId` / `token` unset in
`shell.json`.

## Settings

| Key              | Default    | Meaning                                                      |
|------------------|------------|-------------------------------------------------------------|
| `units`          | `metric`   | `metric` (°C, km/h, mb) or `imperial` (°F, mph, inHg)       |
| `refreshMinutes` | `10`       | Auto-refresh interval; clamped to a minimum of 5            |
| `token`          | *(unset)*  | Tempest API token; overrides `$TEMPEST_TOKEN`               |
| `stationId`      | *(unset)*  | Optional; blank = first station on the token's account. Overrides `$TEMPEST_STATION_ID` |

## Interactions

| Action         | Result                                                       |
|----------------|-------------------------------------------------------------|
| Left click     | Toggle the detail popup                                     |
| Middle click   | Force a refresh                                             |
| Right click    | Send a desktop notification with the full current summary   |

Inside the popup, the gear (top-right) opens the settings form; `Enter` in the
popup opens it too, `Esc` closes it.

The popup also responds to the shell's panel IPC:

```bash
omarchy-shell shell toggle io.github.dreed47.tempest-weather
```

## How it works

`Panel.qml` owns a `curl` process that fetches
`https://swd.weatherflow.com/swd/rest/better_forecast` for the configured
station on the refresh interval and whenever the panel is opened. The last good
response stays on screen if a later fetch fails, and failed fetches retry a few
times before waiting for the next interval. `Model.js` holds the pure parsing
and formatting helpers (Tempest `icon` string → Nerd Font glyph, unit
handling, forecast shaping) and has no QML dependencies.

## License

MIT — see [LICENSE](LICENSE).

This project is not affiliated with WeatherFlow or Tempest.
