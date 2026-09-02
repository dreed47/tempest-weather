// Pure helpers for the Tempest Weather plugin. No QML imports so this file can
// also be exercised from plain JS. The panel wraps each of these with its
// own unit-aware convenience methods.

// ---- Icons -----------------------------------------------------------------
//
// WeatherFlow's Better Forecast API returns an `icon` string on both the
// current conditions and each daily forecast entry. The vocabulary is small
// and stable:
//
//   clear-day            clear-night
//   partly-cloudy-day    partly-cloudy-night
//   cloudy               foggy               windy
//   rainy                possibly-rainy-day / -night
//   sleet                possibly-sleet-day / -night
//   snow                 possibly-snow-day  / -night
//   thunderstorm         possibly-thunderstorm-day / -night
//
// Map each to a Nerd Font "Weather Icons" glyph. The code points match the
// ones Omarchy's built-in weather widget uses so the two look consistent.
// Stored as code points and resolved with fromCharCode so this source file
// stays plain ASCII.
var WEATHER_CODEPOINTS = {
  "clear-day": 0xe30d,           // wi-day-sunny
  "clear-night": 0xe32b,         // wi-night-clear
  "partly-cloudy-day": 0xe302,   // wi-day-cloudy
  "partly-cloudy-night": 0xe32e, // wi-night-alt-cloudy
  "cloudy": 0xe33d,              // wi-cloud
  "foggy": 0xe313,               // wi-day-fog
  "windy": 0xe31e,               // wi-windy
  "rainy": 0xe318,               // wi-rain
  "sleet": 0xe3ad,               // wi-sleet
  "snow": 0xe31a,                // wi-snow
  "thunderstorm": 0xe31d         // wi-thunderstorm
}

var DEFAULT_CODEPOINT = 0xe33d // wi-cloud

function glyph(codepoint) {
  return String.fromCharCode(codepoint || DEFAULT_CODEPOINT)
}

// Normalize a Tempest icon string to one of the WEATHER_CODEPOINTS keys, then
// return its glyph. Unknown values fall back to a neutral cloud.
function iconForTempest(icon) {
  var key = String(icon || "").toLowerCase().replace(/^\s+|\s+$/g, "")
  if (key === "") return glyph(DEFAULT_CODEPOINT)
  if (WEATHER_CODEPOINTS[key]) return glyph(WEATHER_CODEPOINTS[key])

  // "possibly-rainy-day" -> "rainy"; "partly-cloudy-night" stays as-is.
  var base = key.replace(/^possibly-/, "").replace(/-(day|night)$/, "")
  if (WEATHER_CODEPOINTS[base]) return glyph(WEATHER_CODEPOINTS[base])
  if (WEATHER_CODEPOINTS[base + "-day"]) return glyph(WEATHER_CODEPOINTS[base + "-day"])

  if (base.indexOf("thunder") !== -1) return glyph(WEATHER_CODEPOINTS["thunderstorm"])
  if (base.indexOf("snow") !== -1) return glyph(WEATHER_CODEPOINTS["snow"])
  if (base.indexOf("sleet") !== -1 || base.indexOf("hail") !== -1) return glyph(WEATHER_CODEPOINTS["sleet"])
  if (base.indexOf("rain") !== -1 || base.indexOf("drizzle") !== -1) return glyph(WEATHER_CODEPOINTS["rainy"])
  if (base.indexOf("fog") !== -1 || base.indexOf("mist") !== -1 || base.indexOf("haze") !== -1) return glyph(WEATHER_CODEPOINTS["foggy"])
  if (base.indexOf("wind") !== -1) return glyph(WEATHER_CODEPOINTS["windy"])
  if (base.indexOf("cloud") !== -1) return glyph(WEATHER_CODEPOINTS["cloudy"])
  if (base.indexOf("clear") !== -1 || base.indexOf("sunny") !== -1) return glyph(WEATHER_CODEPOINTS["clear-day"])
  return glyph(DEFAULT_CODEPOINT)
}

// ---- Numbers -------------------------------------------------------------

function roundedTemp(value) {
  if (value === undefined || value === null || value === "") return ""
  var n = parseFloat(String(value))
  return isNaN(n) ? "" : String(Math.round(n))
}

function roundedTo(value, digits) {
  if (value === undefined || value === null || value === "") return ""
  var n = parseFloat(String(value))
  if (isNaN(n)) return ""
  var f = Math.pow(10, digits || 0)
  return String(Math.round(n * f) / f)
}

// ---- Units --------------------------------------------------------------

function normalizedUnits(value) {
  return String(value || "").replace(/^\s+|\s+$/g, "").toLowerCase() === "imperial"
    ? "imperial" : "metric"
}

// Query-string values understood by the Better Forecast endpoint.
function apiUnitParams(units) {
  return normalizedUnits(units) === "imperial"
    ? { temp: "f", wind: "mph", pressure: "inhg", distance: "mi", precip: "in" }
    : { temp: "c", wind: "kph", pressure: "mb", distance: "km", precip: "mm" }
}

// Human-facing unit suffixes for the same choice.
function unitLabels(units) {
  return normalizedUnits(units) === "imperial"
    ? { temp: "F", wind: "mph", pressure: "inHg" }
    : { temp: "C", wind: "km/h", pressure: "mb" }
}

// ---- Dates -----------------------------------------------------------------

var WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

// Tempest daily entries carry `day_start_local` as a Unix epoch in seconds.
function dayName(epochSeconds, formatter) {
  var n = parseInt(String(epochSeconds || ""), 10)
  if (isNaN(n)) return ""
  var d = new Date(n * 1000)
  if (isNaN(d.getTime())) return ""
  return formatter ? formatter(d) : WEEKDAYS[d.getDay()]
}

// ---- Report shaping ------------------------------------------------------

function currentConditions(report) {
  return report && report.current_conditions ? report.current_conditions : null
}

// First `count` daily forecast entries, normalized to a flat shape the panel
// can render directly.
function forecastDays(report, count, formatter) {
  var daily = report && report.forecast && report.forecast.daily ? report.forecast.daily : []
  var out = []
  for (var i = 0; i < daily.length && out.length < (count || 5); i++) {
    var d = daily[i]
    if (!d) continue
    out.push({
      epoch: d.day_start_local,
      name: dayName(d.day_start_local, formatter),
      conditions: d.conditions || "",
      icon: iconForTempest(d.icon),
      high: roundedTemp(d.air_temp_high),
      low: roundedTemp(d.air_temp_low),
      precip: (d.precip_probability === undefined || d.precip_probability === null)
        ? "" : String(Math.round(parseFloat(d.precip_probability)))
    })
  }
  return out
}

function pressureTrendLabel(trend) {
  var t = String(trend || "").toLowerCase()
  if (t === "rising" || t === "falling" || t === "steady") return t
  return t
}

// One-line-per-field summary for the right-click desktop notification.
function summaryLines(report, units) {
  var c = currentConditions(report)
  if (!c) return ["No data from the Tempest station yet."]
  var u = unitLabels(units)
  var deg = String.fromCharCode(0x00b0)
  var lines = []
  lines.push(roundedTemp(c.air_temperature) + deg + u.temp
    + (c.conditions ? "  " + c.conditions : "")
    + "  (feels " + roundedTemp(c.feels_like) + deg + u.temp + ")")
  lines.push("Humidity " + roundedTemp(c.relative_humidity) + "%"
    + "   Dew point " + roundedTemp(c.dew_point) + deg + u.temp)
  lines.push("Wind " + roundedTo(c.wind_avg, 0) + " " + u.wind
    + (c.wind_direction_cardinal ? " " + c.wind_direction_cardinal : "")
    + " (gust " + roundedTo(c.wind_gust, 0) + " " + u.wind + ")")
  lines.push("Pressure " + roundedTo(c.sea_level_pressure, 2) + " " + u.pressure
    + " (" + pressureTrendLabel(c.pressure_trend) + ")"
    + "   UV " + roundedTo(c.uv, 0))
  var days = forecastDays(report, 5)
  for (var i = 0; i < days.length; i++) {
    lines.push(days[i].name + ": " + days[i].conditions
      + ", " + days[i].high + deg + "/" + days[i].low + deg
      + ", precip " + days[i].precip + "%")
  }
  return lines
}

if (typeof module !== "undefined") {
  module.exports = {
    iconForTempest: iconForTempest,
    roundedTemp: roundedTemp,
    roundedTo: roundedTo,
    normalizedUnits: normalizedUnits,
    apiUnitParams: apiUnitParams,
    unitLabels: unitLabels,
    dayName: dayName,
    currentConditions: currentConditions,
    forecastDays: forecastDays,
    pressureTrendLabel: pressureTrendLabel,
    summaryLines: summaryLines
  }
}
