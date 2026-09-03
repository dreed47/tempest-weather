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

## Files

| File | Role |
|---|---|
| `manifest.json` | Plugin id/version/kind. `barWidget.defaultSection: "right"`, `defaults` + inline `schema` for `units` / `refreshMinutes` / `token` / `stationId`. Bump `version` on every release. |
| `BarWidget.qml` (~96 lines) | The bar pill. Extends `qs.Ui` `BarWidget`. Lazy-loads `Panel.qml`, injects `bar`/`settings`/`anchorItem`/`hostWidget`, and forwards the bar's popout contract (`opened`, `open`, `close`, `popoutSwitchClosing`, `closeForPopoutSwitch`). `BarIconButton` shows `panel.label`; press routing: left = toggle popup, middle = `refresh()`, right = `notify()` (desktop notification via `omarchy-notification-send`). |
| `Panel.qml` (~899 lines) | The popup + all the logic. Extends `qs.Ui` `Panel`; UI is a `KeyboardPanel` + `PanelKeyCatcher` + `Flickable` + `Column`. Owns the `curl` fetch, the settings form, and every derived property. |
| `Model.js` (~207 lines) | Pure helpers, no QML imports (so `node -e` can test them): Tempest `icon` string → Nerd Font glyph, unit params/labels, `dayName`, `forecastDays`, `pressureTrendLabel`, `relativeAge`, `summaryLines`. Every export is also in the `module.exports` block at the bottom. |
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
refetch kicks off.

## Gotchas (cost real time — do not relearn)

- **Section matters.** The widget must sit in the bar's `right` section. In
  `center`, `KeyboardPanel` with `centerOnBar: false` anchors the popup off the
  left screen edge. Fix if it drifts: `omarchy bar move io.github.dreed47.tempest-weather --section right --after omarchy.tray`.
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
