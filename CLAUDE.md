# CLAUDE.md — Tempest Weather plugin

Orientation for an agent (or a returning developer) picking this repo up cold.
Read this first, then the file you need — you should not have to read the whole
tree to make a change.

## What this is

An Omarchy shell **bar widget** (Quickshell/QML) for people who own a physical
[WeatherFlow Tempest](https://shop.tempest.earth/products/tempest) station. It
shows that station's live sensor data (not a modelled city forecast) via the
account's [Better Forecast API](https://weatherflow.github.io/Tempest/api/).

- Published: <https://github.com/dreed47/tempest-weather> (`main`).
- Marketplace: submitted as `omacom/omarchy-plugin-marketplace` issue **#4532**.
  As of 2026-09-03 it is `validated` but `security-review-required` — a false
  positive on `service-management` from an old README line, since removed
  (`e298970`). Waiting on an `omacom` maintainer; nothing to do on our side.
- Installs to `~/.config/omarchy/plugins/io.github.dreed47.tempest-weather/`
  (named by the manifest `id`, not the repo name).
- **`alerts-sandbox` branch** adds an audible lightning / rain-snow-start alert
  service. It stays on that branch (not merged to `main`, not resubmitted)
  until #4532 is accepted and the alerts are proven on a real storm. See the
  "Alert service" section below.

## Files

| File | Role |
|---|---|
| `manifest.json` | Plugin id/version/kind. `barWidget.defaultSection: "right"`, `defaults` + inline `schema` for `units` / `refreshMinutes` / `token` / `stationId`. Bump `version` on every release. |
| `BarWidget.qml` (~96 lines) | The bar pill. Extends `qs.Ui` `BarWidget`. Lazy-loads `Panel.qml`, injects `bar`/`settings`/`anchorItem`/`hostWidget`, and forwards the bar's popout contract (`opened`, `open`, `close`, `popoutSwitchClosing`, `closeForPopoutSwitch`). `BarIconButton` shows `panel.label`; press routing: left = toggle popup, middle = `refresh()`, right = `notify()` (desktop notification via `omarchy-notification-send`). |
| `Panel.qml` (~899 lines) | The popup + all the logic. Extends `qs.Ui` `Panel`; UI is a `KeyboardPanel` + `PanelKeyCatcher` + `Flickable` + `Column`. Owns the `curl` fetch, the settings form, and every derived property. |
| `Model.js` (~280 lines) | Pure helpers, no QML imports (so `node -e` can test them): Tempest `icon` string → Nerd Font glyph, unit params/labels, `dayName`, `forecastDays`, `pressureTrendLabel`, `relativeAge`, `summaryLines`, and the alert-edge helpers `iconWet` / `precipKind` / `detectLightning` / `detectPrecipStart`. Every export is also in the `module.exports` block at the bottom. |
| `AlertService.qml` (~305 lines) | **alerts-sandbox only.** Headless `service`-kind entry point. Own short `curl` poll of better_forecast, diffs successive responses through `Model.js`, and on a lightning / precip-start edge runs `pw-play` + `omarchy-notification-send`. No UI, no `qs.*` imports. See "Alert service" below. |
| `README.md` / `CHANGELOG.md` | User-facing. Plain English. |
| `preview.png` / `settings.png` | Marketplace screenshots — regenerate when the popup layout changes. |

## Panel.qml property chains

- Config: `configuredStationId` / `token` (setting → env fallback) →
  `stationId` (configured, else `discoveredStationId` from `GET /stations`) →
  `configured` = `hasToken && stationId != ""`.
- `requestUrl` (better_forecast + unit params) → `fetchProc` (curl) → `report`
  (kept on failure so stale data stays visible) → `current` =
  `report.current_conditions`.
- Display: `current` → `tempStr` / `glyphStr` / `conditionText` /
  `forecastDays` / `stationName` (`report.location_name`) / `readingEpoch`
  (`current.time`) → `readingAge` (`Model.relativeAge`, re-ticked by a 60s
  `Timer` that runs only while `opened`) → `headerText`
  (`● <STATION> — LIVE · UPDATED Nm AGO`).
- `label` (pill text): glyph + temp when data is in, else a neutral cloud so a
  fresh install is still visible/clickable.
- `tooltip` (pill hover): names the station — do **not** reuse it for the
  in-popup condition line, that's `conditionText`.

## Settings form

Gear in the popup's top strip toggles `editingSettings`. Fields (`stationId`,
`token`, `units`, `refreshMinutes`) prefill from current settings; **Save**
runs `omarchy-bar set <id> <key> <value>` once per field via `settingsSaveProc`
(a queue re-armed `onExited`). The shell hot-reloads `shell.json` and patches
the live widget's `settings`, so the config properties re-evaluate and a
refetch kicks off. The ALERTS section rows write `alertLightning`,
`alertLightningMaxDistance`, `alertPrecipStart`, `alertNotify`,
`alertPollSeconds` the same way.

## Alert service (`alerts-sandbox` branch)

- Manifest carries two kinds: `["bar-widget", "service"]`, `keepLoaded: true`,
  `entryPoints.service: "AlertService.qml"`. The shell mounts the service for
  any *enabled* plugin that declares kind `service`; the widget being placed on
  the bar is what "enables" it, so there is no separate enable step.
- The service instance is injected `shell` / `manifest` (not `settings`). It
  reads config from `shell.shellConfig` — it scans the bar layout / `plugins[]`
  for its own `id` and pulls `token` / `stationId` / `units` + the `alert*`
  keys. **Do not also push config in from `BarWidget.qml`** — an earlier
  version did and the two sources raced, making `canPoll` flicker and the poll
  timer thrash between 60 s and the 90 s default.
- `BarWidget.qml` still resolves `bar.shell.serviceFor(id)` read-only, just to
  show a bolt (`0xf0e7`) on the pill while `alertService.lightningActive`.
- Poll → `Model.detectLightning` / `Model.detectPrecipStart` (pure, in
  `Model.js`) → `fireLightning` / `firePrecip` → `pw-play <sound>` +
  `omarchy-notification-send`. De-dup: `lastLightningEpoch` (only a strike
  newer than both it and `startedAtEpoch` fires) and `lastPrecipDay` (one
  precip-start alert per local day). State is in-memory; the `startedAtEpoch`
  gate is what stops a restart mid-storm replaying old strikes.
- Sounds: `sounds/{lightning,rain,snow}.ogg` ship with the plugin — the
  freedesktop sound + ~1 s leading silence (an idle-suspended HDMI/receiver
  sink wakes too slowly for a bare 0.5 s clip; a real user hit exactly this).
  Both `AlertService.qml` and `Panel.qml` resolve the dir with
  `decodeURIComponent(Qt.resolvedUrl(".").replace(/^file:\/\//,""))`, no
  `manifest.__sourceDir` needed. `alertLightningSound`/`alertPrecipSound`/
  `alertSnowSound` (settable in the form's SOUNDS block or shell.json) override
  per type; blank = bundled default. The form's **test** buttons run the same
  `pw-play` path via `Panel.qml`'s `soundTestProc`.
- **NWS alerts** (`alertNws`, off by default, US only): a separate poll of
  `api.weather.gov/alerts/active?point=<lat>,<lon>` (needs a `User-Agent`
  header or it 403s). Coords (`lat`/`lon`) are read from the `better_forecast`
  response in `evaluate()` — no extra Tempest call. `Model.nwsQualifies`
  filters (status Actual, messageType Alert/Update, severity ≥
  `alertNwsMinSeverity` default "Severe"). `seenNwsIds` de-dups by alert id;
  `nwsBaselined` makes the first post-startup poll adopt active alerts silently
  (like precip's baseline). `nwsActive` → warning triangle (`0xf071`) on the
  pill, alongside the lightning bolt. Bundled `sounds/nws.ogg`; override
  `alertNwsSound`.
- `AlertService.nwsAlerts` (array of `properties` objects, severity-sorted) is
  read by `Panel.qml` for the popup banner: event + `headline`, a "full text"
  toggle (`nwsExpanded`) showing `Model.nwsSummary` (description + instruction),
  and a link that opens `forecast.weather.gov/MapClick.php?lat=&lon=` (the only
  reliable human page — per-alert `alerts.weather.gov` URLs were retired, and
  the API `@id` returns JSON). Panel resolves the service itself via
  `bar.shell.serviceFor(id)`.
- Sound picker is an **in-panel** browser (`browsingSound` / `browseEntries`,
  `browseProc` runs `find -maxdepth 1`, `applyBrowseListing` parses `%y\t%f`).
  A `QtQuick.Dialogs` `FileDialog` is installed and works, but opens as a
  normal toplevel *behind* the `WlrLayer.Overlay` popup — unusable. Omarchy's
  own image-picker is likewise a custom in-overlay picker, not a native
  dialog.
- **`AlertService.qml`, not `Service.qml`.** A file literally named
  `Service.qml` collided in Quickshell's QML type cache with the first-party
  `Service.qml` files and threw a misleading "File name case mismatch"; the
  rename plus `rm -rf ~/.cache/quickshell/qmlcache` cleared it.
- Test without a storm: set `debugForce: true` in `AlertService.qml` (bypasses
  the `startedAtEpoch` gate) so the strike already in the API response fires
  once. Set it back to `false` and strip the `[tempest-alert]` `console.log`
  lines before committing.
- Real-time seam: a UDP sidecar (hub broadcasts `evt_strike` / `evt_precip` on
  `:50222`) or the cloud WebSocket can feed the same `evaluate()` path later;
  the poll stays as the always-available fallback.

## Gotchas (cost real time — do not relearn)

- **Bar button type.** The pill paints `<glyph>  72°` — a multi-char text
  label, so `BarWidget.qml` uses `WidgetButton` (width sized to the label,
  like `omarchy.clock`), *not* `BarIconButton` (icon-only, clamped to a fixed
  square slot). With `BarIconButton` the temperature overflowed the button box
  and overlapped the next widget in the `center` section. The widget works in
  any bar section (`left` / `center` / `right`); the popup anchors under the
  pill in all three.
- **`omarchy restart shell`** is required after editing `manifest.json` or the
  bar layout. `omarchy-shell shell rescanPlugins` only hot-reloads QML bodies,
  not a re-mount, so widget/manifest changes look like they "did nothing".
- Imports `qs.Ui` and `qs.Commons` — these resolve only inside the running
  `omarchy-shell` process (they are the shell's own modules). `omarchy plugin
  validate .` does not catch QML type errors; the shell log does.
- Credentials never live in this repo. `omarchy-bar set` (settings form) or
  `$TEMPEST_TOKEN` / `$TEMPEST_STATION_ID`. Station id is optional — the token
  is account-scoped and `/stations` gives the first station.
- Weather glyph code points in `Model.js` deliberately match Omarchy's
  built-in `omarchy.weather` widget so the two look consistent.
- `omarchy` dispatcher and `omarchy-*` binaries are on `PATH` inside the
  shell's `Process` env; `curl` ships with Omarchy.

## Dev loop

```bash
cd ~/.config/omarchy/plugins/io.github.dreed47.tempest-weather
node -e 'const M=require("./Model.js"); /* exercise a helper */'   # test Model.js
omarchy plugin validate .
omarchy restart shell            # after manifest/layout changes
omarchy-shell shell toggle io.github.dreed47.tempest-weather '{}'  # open the popup
grim -o DP-2 /tmp/shot.png && magick /tmp/shot.png -crop 1000x400+2793+52 +repage /tmp/popup.png
```

Shell log: `journalctl --user -f | grep -i tempest` (ignore the harmless
"Handler was registered but will not be used" IPC warning — the bar
auto-registers the widget's route and our own `IpcHandler` is the spare).

## Release checklist

1. Bump `manifest.json` `version`.
2. Add a `## <version>` block to `CHANGELOG.md`.
3. Update `README.md` if behaviour/config changed; regenerate `preview.png` /
   `settings.png` if the popup layout changed.
4. Commit (trailer: `Co-Authored-By` + `Claude-Session`), `git push origin main`.
5. The marketplace revalidates on the submission issue, not on push — no action
   needed unless a maintainer asks.
