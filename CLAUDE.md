# CLAUDE.md — Tempest Weather plugin

Orientation for an agent (or a returning developer) picking this repo up cold.
Read this first, then the file you need — you should not have to read the whole
tree to make a change.

## What this is

An Omarchy shell **bar widget** (Quickshell/QML) for people who own a physical
[WeatherFlow Tempest](https://shop.tempest.earth/products/tempest) station. It
shows that station's live sensor data (not a modelled city forecast) via the
account's [Better Forecast API](https://weatherflow.github.io/Tempest/api/).

- Published: <https://github.com/dreed47/tempest-weather> (`main`) — the alert
  service (lightning / rain-snow / NWS storm warnings + in-popup radar) has
  been merged into `main` as of `0.5.0`; it's no longer a separate branch. See
  the "Alert service" section below.
- Marketplace: submitted as `omacom/omarchy-plugin-marketplace` issue **#4532**.
  Stuck in `security-review-required` since 2026-09-02 with no maintainer
  reply despite pings; the original flag was a false positive on
  `service-management` from an old README line, since removed (`e298970`).
  Decided not to gate development on it — `main` now carries the full feature
  set regardless of review status; the review can keep happening in the
  background. `main` merging in the `service` kind will likely surface a real
  (expected, already-documented) capability flag on the next automated scan —
  see the README's "What it runs and connects to" section.
- Installs to `~/.config/omarchy/plugins/io.github.dreed47.tempest-weather/`
  (named by the manifest `id`, not the repo name).

## Files

| File | Role |
|---|---|
| `manifest.json` | Plugin id/version/kind. `barWidget.defaultSection: "right"`, `defaults` + inline `schema` for `units` / `refreshMinutes` / `token` / `stationId`. Bump `version` on every release. |
| `BarWidget.qml` (~96 lines) | The bar pill. Extends `qs.Ui` `BarWidget`. Lazy-loads `Panel.qml`, injects `bar`/`settings`/`anchorItem`/`hostWidget`, and forwards the bar's popout contract (`opened`, `open`, `close`, `popoutSwitchClosing`, `closeForPopoutSwitch`). `BarIconButton` shows `panel.label`; press routing: left = toggle popup, middle = `refresh()`, right = `notify()` (desktop notification via `omarchy-notification-send`). |
| `Panel.qml` (~899 lines) | The popup + all the logic. Extends `qs.Ui` `Panel`; UI is a `KeyboardPanel` + `PanelKeyCatcher` + `Flickable` + `Column`. Owns the `curl` fetch, the settings form, and every derived property. |
| `Model.js` (~280 lines) | Pure helpers, no QML imports (so `node -e` can test them): Tempest `icon` string → Nerd Font glyph, unit params/labels, `dayName`, `forecastDays`, `pressureTrendLabel`, `relativeAge`, `summaryLines`, and the alert-edge helpers `iconWet` / `precipKind` / `detectLightning` / `detectPrecipStart`. Every export is also in the `module.exports` block at the bottom. |
| `AlertService.qml` (~305 lines) | Headless `service`-kind entry point. Own short `curl` poll of better_forecast, diffs successive responses through `Model.js`, and on a lightning / precip-start edge runs `pw-play` + `omarchy-notification-send`. No UI, no `qs.*` imports. See "Alert service" below. |
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

## Alert service

- Manifest carries two kinds: `["bar-widget", "service"]`, `keepLoaded: true`,
  `entryPoints.service: "AlertService.qml"`. The shell mounts the service for
  any *enabled* plugin that declares kind `service`; the widget being placed on
  the bar is what "enables" it, so there is no separate enable step.
- The service instance is injected `shell` / `manifest` (not `settings`). It
  reads config from `shell.shellConfig.bar.layout` (older shells) falling back
  to `shell.barConfig.layout` (Omarchy 4.0.3+, which dropped `shellConfig`
  from the scoped plugin shell) — it scans for its own `id` and pulls `token`
  / `stationId` / `units` + the `alert*` keys. **Do not also push config in
  from `BarWidget.qml`** — an earlier version did and the two sources raced,
  making `canPoll` flicker and the poll timer thrash between 60 s and the
  90 s default.
- **The Tempest token never touches any process's own argv.** `ps` and
  `/proc/<pid>/cmdline` show every local user's command line, so the two
  fetches that carry the token (`better_forecast`, `stations` — in both
  `AlertService.qml` and `Panel.qml`) run as
  `["bash", "-c", 'read -r URL && printf "url = %s\n" "$URL" | curl … -K -']`
  with the URL delivered via `Process.write()` in `onStarted`, not as a
  command-line argument. `read -r` takes exactly one line — no EOF needed, so
  this works with Quickshell's write-only `Process.write()` — and the inner
  `printf | curl -K -` pipe is bash's own, closed automatically once `printf`
  finishes, which is what gives curl's `-K -` config reader the EOF it needs.
  **`curl -K -` fed directly off `Process.write()` (no bash wrapper) hangs
  forever** — Quickshell exposes no API to close/EOF a process's stdin, and
  `--max-time` only bounds the transfer, not curl's pre-transfer config read.
  A `bash -c 'read URL && exec curl … "$URL"'` wrapper (no inner pipe) does
  **not** fix the leak either — `exec` still hands curl the expanded URL as
  its own argv. Both were tried and disproven live (`ps` during the poll)
  before landing on the `read` + inner `printf | curl -K -` pipe. The NWS/
  radar fetches (`pointsProc`, `nwsProc`) carry no secret, so they still run
  `curl` directly with the URL in argv — fine, nothing sensitive in it.
- `radarStation` (both the `alertRadarSite` override and the value parsed out
  of the `api.weather.gov/points` response) is whitelisted with
  `Model.isValidRadarStation` (`^[A-Z0-9]{3,5}$`) before use — it gets spliced
  into a `radar.weather.gov` URL and an `AnimatedImage` source, so an
  unvalidated value there (a bad API response, a mistyped override) would
  otherwise reach a network/image-loader path unchecked.
- `BarWidget.qml` still resolves `bar.shell.serviceFor(id)` read-only, just to
  show a bolt (`0xf0e7`) on the pill while `alertService.lightningActive`.
- Poll → `Model.detectLightning` / `Model.detectPrecipStart` (pure, in
  `Model.js`) → `fireLightning` / `firePrecip` → `pw-play <sound>` +
  `omarchy-notification-send` (with `-t <alertNotifyTimeout*1000>` when the
  setting is >0; every alert fires `-u normal` — `critical` was tried first
  but mako/swaync keep those pinned regardless of `-t`, defeating
  `alertNotifyTimeout`). De-dup: `lastLightningEpoch` (only a strike
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
  response in `evaluate()` — no extra Tempest call. `Model.nwsQualifies(p, level)`
  filters: status Actual, messageType Alert/Update, and tier ≥ the cumulative
  `alertNwsLevel` (`warnings` (default, tier rank 3) → `watches` (2) →
  `advisories` (1)). `Model.nwsTier` classifies by the event-name suffix;
  Statement / Emergency / unrecognised fold into the warning tier. Changing the
  level re-baselines (`onNwsLevelChanged`) so it isn't a fresh alarm. The form
  shows it as a 3-stop cumulative control (each pill highlights when its rank ≤
  the selected rank). `seenNwsIds` de-dups by alert id;
  `nwsBaselined` makes the first post-startup poll adopt active alerts silently
  (like precip's baseline). `nwsActive` → warning triangle (`0xf071`) on the
  pill, alongside the lightning bolt. Bundled `sounds/nws.ogg`; override
  `alertNwsSound`.
- **Radar** (Panel.qml, `radarExpanded` default false): NWS RIDGE loop GIF
  `radar.weather.gov/ridge/standard/<SITE>_loop.gif` (600x550, ~1 MB, 10
  frames) in an `AnimatedImage`. `<SITE>` from `AlertService.radarStation` —
  resolved via `api.weather.gov/points/<lat,lon>` (**≤4 decimal places or it
  301s**; `coord4` + `curl -fsSL` handle that) → `.properties.radarStation`,
  or the `alertRadarSite` override. `source` is `""` unless expanded, and a
  150 s `Timer` (runs only while expanded + `opened`) bumps `radarNonce` in the
  URL to force a refetch. Tap → `omarchy-launch-browser` the per-station page.
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
