# Tempest Weather

An Omarchy shell bar widget that shows conditions from **your own
[WeatherFlow Tempest](https://tempest.earth/) weather station** instead of a
modelled forecast for your city.

> **This plugin is for people who own a Tempest weather station**
> ([shop.tempest.earth](https://shop.tempest.earth/products/tempest)). It reads
> that station's live sensor data through your Tempest account. If you don't
> have a station, use Omarchy's built-in `omarchy.weather` widget instead — it
> works from your location with no hardware.

The pill shows the current condition glyph and temperature. Clicking it opens a
popup headed `● <STATION NAME> — LIVE · UPDATED <n>m ago`, then feels-like,
wind, humidity, sea-level pressure and its trend, UV, dew point, and a
three-day forecast — all pulled straight from the station owner's
[Better Forecast API](https://weatherflow.github.io/Tempest/api/), so the
readings match the Tempest app. The header names your station and shows how
fresh the reading is, so it's never mistaken for a city forecast.

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
> not keep the token there, use Option C.

### Option C — environment variables

Put the credentials where your session exposes environment variables — for a
uwsm/Hyprland session, `~/.config/environment.d/tempest.conf`:

```
TEMPEST_STATION_ID=12345
TEMPEST_TOKEN=your-tempest-token
```

Log out and back in so `omarchy-shell` inherits them, then leave `stationId` /
`token` unset in `shell.json`.

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

## Alerts

The plugin also ships a headless alert service that runs whenever the widget is
enabled. On its own short poll it watches for the following and, when one
happens, plays a sound (and, by default, raises a desktop notification):

| Alert | Fires when |
|-------|------------|
| Lightning strike | `lightning_strike_last_epoch` advances to a strike newer than the service started; optionally only within a distance you set |
| Rain / snow start | the current conditions cross from dry to wet (a `clear` → `rainy` / `snow` / `thunderstorm` edge) |
| Storm warning (NWS) | a new US National Weather Service **warning** for the station's location is issued at severity Severe or Extreme (severe-thunderstorm / tornado / flood warnings). Watches and advisories are excluded by default — turn off "warnings only" to include them. |

The first two are your station's own sensors — hyper-local, real-time. The NWS
alert is a separate area feed (`api.weather.gov`, US only, no key), keyed off
the station's coordinates, which the plugin already gets from the forecast
response. Watches/warnings active *before* the service starts are adopted
silently, so a restart mid-warning is not a fresh alarm; a newly issued one
sounds.

> **Alerts (or the forecast) for the wrong area?** Both use the latitude and
> longitude registered for your station in your Tempest account — not your
> device's location. If they seem off, open the Tempest app or
> [tempestwx.com](https://tempestwx.com), go to your station's settings, and
> check/correct its location. That fixes the forecast, the NWS alerts, and the
> timezone together.

All alerts are **off by default**. Turn them on in the settings form (the gear
in the popup) — the ALERTS section has on/off switches for each, a lightning
max-distance, a notification switch, the poll interval, and a SOUNDS block with
a file-path field and a **test** button per alert type. Because alerts come
from a poll, they lag by up to one interval (default 90 s, minimum 60 s); they
are a heads-up, not a life-safety warning.

The bar pill flags a live alert even with the popup closed: a warning triangle
while an NWS alert is active, a lightning-bolt for 20 minutes after a strike.

While an NWS alert is active the popup shows a banner at the top — the event
name and the NWS one-line headline, a **full text** toggle that expands the
complete alert text inline, and a **details & radar on weather.gov** link to
the point forecast page for the station's coordinates (radar with the warning
polygons, and the official full text).

### Sounds

The plugin bundles its alert sounds (`sounds/lightning.ogg`, `rain.ogg`,
`snow.ogg`, `nws.ogg`): each has ~1 second of leading silence in front. That
silence matters on an HDMI or AV-receiver output that powers down when idle — it
can take a moment to wake, and a bare 0.5 s notification sound finishes before
you hear anything. If your notification sounds already work, the padding is
inaudible.

Leave a sound field blank to use the bundled default; set it to any path
(`.ogg` / `.wav` / `.oga` / `.flac` / `.opus`, whatever `pw-play` accepts) to
override. Type or paste a path, or use the **folder button** to open an
in-panel file browser — tap a folder to open it, an audio file to pick it. The
`▶` button plays whatever that row currently points at. These map to the
`alertLightningSound` / `alertPrecipSound` / `alertSnowSound` / `alertNwsSound`
keys, which you can also set directly in `shell.json`.

Two knobs control which NWS alerts count:

- **warnings only** (`alertNwsWarningsOnly`, default on) — a switch in the
  ALERTS section. On: only "… Warning" events. Off: also Watches, Advisories,
  and Statements.
- `alertNwsMinSeverity` (shell.json only, default `Severe`) — the severity
  floor. `Moderate` includes more; `Extreme` is life-threatening only.

The service reads the same token, station, and units as the widget, so it needs
the widget placed on the bar; there is nothing else to configure.

## How it works

`Panel.qml` owns a `curl` process that fetches
`https://swd.weatherflow.com/swd/rest/better_forecast` for the configured
station on the refresh interval and whenever the panel is opened. The last good
response stays on screen if a later fetch fails, and failed fetches retry a few
times before waiting for the next interval. `Model.js` holds the pure parsing
and formatting helpers (Tempest `icon` string → Nerd Font glyph, unit
handling, forecast shaping, alert-edge detection) and has no QML dependencies.

`AlertService.qml` is the headless alert service. It runs its own shorter
`curl` poll of the same endpoint, diffs consecutive responses through
`Model.js`, and — when NWS alerts are on — also polls
`https://api.weather.gov/alerts/active?point=<lat>,<lon>` for the station's
coordinates. On a lightning strike, a precip-start edge, or a newly issued
qualifying NWS alert it runs `pw-play` for the sound and
`omarchy-notification-send` for the notification. It holds no UI.

## License

MIT — see [LICENSE](LICENSE).

This project is not affiliated with WeatherFlow or Tempest.
