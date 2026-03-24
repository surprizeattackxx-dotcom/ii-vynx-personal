pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import QtQuick
import QtPositioning

import qs.modules.common

Singleton {
    id: root
    readonly property int fetchInterval: Config.options.bar.weather.fetchInterval * 60 * 1000
    readonly property string city: Config.options.bar.weather.city
    readonly property bool useUSCS: Config.options.bar.weather.useUSCS
    property bool gpsActive: Config.options.bar.weather.enableGPS

    property bool ready: false

    onUseUSCSChanged: { if (root.ready) root.getData(); }
    onCityChanged:    { if (root.ready) root.getData(); }

    property bool isLoading: false
    property bool hasError: false
    property string errorMessage: ""

    property var location: ({
        valid: false,
        lat: 0,
        lon: 0
    })

    property var data: ({
        uv: 0,
        humidity: 0,
        sunrise: "",
        sunset: "",
        windDir: "",
        wCode: 0,
        city: "",
        wind: "",
        precip: "",
        visib: "",
        press: "",
        temp: "",
        tempFeelsLike: "",
        tempMin: "",
        tempMax: "",
        description: "",
        dewPoint: "",
        cloudCover: "",
        lastRefresh: "",
    })

    // forecast: list of { dayLabel, wCode, tempMin, tempMax, description }
    property var forecast: []

    // alerts: list of { event }
    property var alerts: []

    // ── Helpers ──────────────────────────────────────────────────────────────

    function degreesToWindDir(deg) {
        const dirs = ["N","NNE","NE","ENE","E","ESE","SE","SSE","S","SSW","SW","WSW","W","WNW","NW","NNW"];
        return dirs[Math.round(deg / 22.5) % 16];
    }

    function isoTimeToHHMM(isoStr) {
        if (!isoStr) return "";
        // "2024-03-16T06:42" → "06:42"
        const t = isoStr.split("T")[1] || "";
        return t.substring(0, 5);
    }

    function isoDateToDayLabel(dateStr) {
        if (!dateStr) return "";
        const d = new Date(dateStr + "T12:00:00");
        const days = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];
        return days[d.getDay()];
    }

    // Map WMO weather codes to the internal wCode values used by Icons.getWeatherIcon
    function wmoToWCode(wmo) {
        if (wmo === 0)            return 113;  // clear sky
        if (wmo === 1)            return 116;  // mainly clear
        if (wmo === 2)            return 119;  // partly cloudy
        if (wmo === 3)            return 122;  // overcast
        if (wmo === 45 || wmo === 48) return 143; // fog
        if (wmo === 51 || wmo === 53 || wmo === 55) return 266; // drizzle
        if (wmo === 56 || wmo === 57) return 281; // freezing drizzle
        if (wmo === 61)           return 296;  // slight rain
        if (wmo === 63)           return 302;  // moderate rain
        if (wmo === 65)           return 308;  // heavy rain
        if (wmo === 66 || wmo === 67) return 311; // freezing rain
        if (wmo === 71)           return 323;  // slight snow
        if (wmo === 73)           return 329;  // moderate snow
        if (wmo === 75)           return 338;  // heavy snow
        if (wmo === 77)           return 335;  // snow grains
        if (wmo === 80)           return 353;  // slight showers
        if (wmo === 81)           return 356;  // moderate showers
        if (wmo === 82)           return 359;  // violent showers
        if (wmo === 85)           return 368;  // slight snow showers
        if (wmo === 86)           return 371;  // heavy snow showers
        if (wmo === 95)           return 389;  // thunderstorm
        if (wmo === 96)           return 392;  // thunderstorm + slight hail
        if (wmo === 99)           return 395;  // thunderstorm + heavy hail
        return 122;
    }

    function wmoToDescription(wmo) {
        const map = {
            0: "Clear sky", 1: "Mainly clear", 2: "Partly cloudy", 3: "Overcast",
            45: "Fog", 48: "Depositing rime fog",
            51: "Light drizzle", 53: "Moderate drizzle", 55: "Dense drizzle",
            56: "Light freezing drizzle", 57: "Dense freezing drizzle",
            61: "Slight rain", 63: "Moderate rain", 65: "Heavy rain",
            66: "Light freezing rain", 67: "Heavy freezing rain",
            71: "Slight snow", 73: "Moderate snow", 75: "Heavy snow",
            77: "Snow grains",
            80: "Slight rain showers", 81: "Moderate rain showers", 82: "Violent rain showers",
            85: "Slight snow showers", 86: "Heavy snow showers",
            95: "Thunderstorm",
            96: "Thunderstorm, slight hail", 99: "Thunderstorm, heavy hail",
        };
        return map[wmo] || "Unknown";
    }

    function cToF(c) { return Math.round(c * 9/5 + 32); }

    // ── Parse Open-Meteo response ─────────────────────────────────────────────

    function refineData(parsed) {
        const cur = parsed.current || {};
        const daily = parsed.daily || {};
        const cityName = parsed.city_name || root.city.split(",")[0] || "City";

        const windSpeedMs  = cur.wind_speed_10m   || 0;  // m/s (requested unit)
        const windDeg      = cur.wind_direction_10m || 0;
        const humidityRaw  = cur.relative_humidity_2m || 0;
        const visibM       = cur.visibility        || 0;  // meters
        const pressHpa     = cur.pressure_msl      || 0;
        const precipMM     = cur.precipitation     || 0;
        const wmo          = cur.weather_code      ?? 0;
        const uvIndex      = cur.uv_index          ?? 0;
        const cloudPct     = cur.cloud_cover       ?? 0;
        const tempC        = cur.temperature_2m    ?? 0;
        const feelsC       = cur.apparent_temperature ?? 0;
        const windKmh      = windSpeedMs * 3.6;

        let temp = {};
        temp.uv          = Math.round(uvIndex);
        temp.humidity    = humidityRaw + "%";
        temp.windDir     = degreesToWindDir(windDeg);
        temp.wCode       = wmoToWCode(wmo);
        temp.city        = cityName;
        temp.description = wmoToDescription(wmo);
        temp.cloudCover  = cloudPct + "%";
        temp.dewPoint    = "";
        temp.sunrise     = isoTimeToHHMM((daily.sunrise || [])[0] || "");
        temp.sunset      = isoTimeToHHMM((daily.sunset  || [])[0] || "");

        // daily min/max come from daily[0]
        const dailyMinC  = (daily.temperature_2m_min || [])[0] ?? tempC;
        const dailyMaxC  = (daily.temperature_2m_max || [])[0] ?? tempC;

        if (root.useUSCS) {
            temp.wind          = (windKmh / 1.60934).toFixed(1) + " mph";
            temp.precip        = (precipMM / 25.4).toFixed(2) + " in";
            temp.visib         = (visibM / 1609.34).toFixed(1) + " mi";
            temp.press         = (pressHpa * 0.02953).toFixed(2) + " inHg";
            temp.temp          = cToF(tempC) + "°F";
            temp.tempFeelsLike = cToF(feelsC) + "°F";
            temp.tempMin       = cToF(dailyMinC) + "°F";
            temp.tempMax       = cToF(dailyMaxC) + "°F";
        } else {
            temp.wind          = windKmh.toFixed(1) + " km/h";
            temp.precip        = precipMM.toFixed(1) + " mm";
            temp.visib         = (visibM / 1000).toFixed(1) + " km";
            temp.press         = pressHpa + " hPa";
            temp.temp          = Math.round(tempC) + "°C";
            temp.tempFeelsLike = Math.round(feelsC) + "°C";
            temp.tempMin       = Math.round(dailyMinC) + "°C";
            temp.tempMax       = Math.round(dailyMaxC) + "°C";
        }

        temp.lastRefresh = DateTime.time + " • " + DateTime.date;
        root.data = temp;
        root.generateAlerts(cur);
    }

    function refineForecast(parsed) {
        const daily = parsed.daily || {};
        const times    = daily.time              || [];
        const codes    = daily.weather_code      || [];
        const mins     = daily.temperature_2m_min || [];
        const maxs     = daily.temperature_2m_max || [];
        const todayStr = new Date().toISOString().slice(0, 10);
        const unit     = root.useUSCS ? "°F" : "°C";

        const days = [];
        for (let i = 0; i < times.length && days.length < 5; i++) {
            if (times[i] === todayStr) continue;
            const wmo    = codes[i] ?? 0;
            const rawMin = mins[i]  ?? 0;
            const rawMax = maxs[i]  ?? 0;
            days.push({
                dayLabel:    isoDateToDayLabel(times[i]),
                wCode:       wmoToWCode(wmo),
                tempMin:     (root.useUSCS ? cToF(rawMin) : Math.round(rawMin)) + unit,
                tempMax:     (root.useUSCS ? cToF(rawMax) : Math.round(rawMax)) + unit,
                description: wmoToDescription(wmo),
            });
        }
        root.forecast = days;
    }

    function generateAlerts(cur) {
        const newAlerts = [];
        const windSpeedMs = cur.wind_speed_10m || 0;
        const tempC       = cur.temperature_2m || 0;
        const uvi         = root.data.uv       || 0;
        const wCode       = root.data.wCode;
        const windKmh     = windSpeedMs * 3.6;

        if (windKmh >= 50) {
            const windStr = root.useUSCS
                ? (windKmh / 1.60934).toFixed(1) + " mph"
                : windKmh.toFixed(1) + " km/h";
            newAlerts.push({ event: Translation.tr("Wind Advisory") + " — " + windStr });
        }

        if (tempC >= 35) {
            const tStr = root.useUSCS ? cToF(tempC) + "°F" : Math.round(tempC) + "°C";
            newAlerts.push({ event: Translation.tr("Heat Advisory") + " — " + tStr });
        } else if (tempC <= -10) {
            const tStr = root.useUSCS ? cToF(tempC) + "°F" : Math.round(tempC) + "°C";
            newAlerts.push({ event: Translation.tr("Freeze Warning") + " — " + tStr });
        }

        if (uvi >= 8)      newAlerts.push({ event: Translation.tr("High UV Index") + " — " + uvi });
        if (wCode === 389) newAlerts.push({ event: Translation.tr("Thunderstorm Warning") });
        if (wCode === 338) newAlerts.push({ event: Translation.tr("Winter Storm Warning") });

        root.alerts = newAlerts;
    }

    // ── Fetch ─────────────────────────────────────────────────────────────────

    // Open-Meteo params (wind in m/s, visibility in meters, pressure in hPa)
    readonly property string _weatherParams: "current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,wind_direction_10m,precipitation,cloud_cover,pressure_msl,visibility,uv_index,weather_code&daily=weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,precipitation_sum&timezone=auto&forecast_days=6&wind_speed_unit=ms"

    function getData() {
        let command;
        if (root.gpsActive && root.location.valid) {
            const lat = root.location.lat;
            const lon = root.location.lon;
            command = `curl -sf "https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&${root._weatherParams}" | jq --arg c "" '. + {city_name: $c}'`;
        } else {
            const cityOnly = root.city.trim().split(",")[0].trim().replace(/'/g, "").split(/\s+/).join("+");
            command = `
GEO=$(curl -sf 'https://geocoding-api.open-meteo.com/v1/search?name=${cityOnly}&count=1&language=en&format=json')
LAT=$(echo "$GEO" | jq -r '.results[0].latitude // empty')
LON=$(echo "$GEO" | jq -r '.results[0].longitude // empty')
CITY=$(echo "$GEO" | jq -r '.results[0].name // "Unknown"')
if [ -z "$LAT" ]; then echo '{"error":"geocode failed"}'; exit 1; fi
curl -sf "https://api.open-meteo.com/v1/forecast?latitude=$LAT&longitude=$LON&${root._weatherParams}" | jq --arg c "$CITY" '. + {city_name: $c}'
`;
        }

        if (fetcher.running) fetcher.running = false;
        fetcher.command = ["bash", "-c", command];
        root.isLoading = true;
        root.hasError  = false;
        fetcher.running = true;
    }

    // ── QML objects ───────────────────────────────────────────────────────────

    Component.onCompleted: {
        root.ready = true;
        if (!root.gpsActive) return;
        console.info("[WeatherService] Starting the GPS service.");
        positionSource.start();
    }

    Process {
        id: fetcher
        command: ["bash", "-c", ""]
        stdout: StdioCollector {
            onStreamFinished: {
                root.isLoading = false;
                if (text.length === 0) {
                    root.hasError     = true;
                    root.errorMessage = "Empty response from weather API.";
                    return;
                }
                try {
                    const parsed = JSON.parse(text);
                    if (parsed.error) {
                        root.hasError     = true;
                        root.errorMessage = parsed.error;
                        console.error(`[WeatherService] ${parsed.error}`);
                        return;
                    }
                    root.refineData(parsed);
                    root.refineForecast(parsed);
                } catch (e) {
                    root.hasError     = true;
                    root.errorMessage = e.message;
                    console.error(`[WeatherService] ${e.message}`);
                }
            }
        }
    }

    PositionSource {
        id: positionSource
        updateInterval: root.fetchInterval

        onPositionChanged: {
            if (position.latitudeValid && position.longitudeValid) {
                root.location.lat   = position.coordinate.latitude;
                root.location.lon   = position.coordinate.longitude;
                root.location.valid = true;
                root.getData();
            } else {
                root.gpsActive = root.location.valid;
                console.error("[WeatherService] Failed to get the GPS location.");
            }
        }

        onValidityChanged: {
            if (!positionSource.valid) {
                positionSource.stop();
                root.location.valid = false;
                root.gpsActive = false;
                root.getData();
                Quickshell.execDetached(["notify-send", Translation.tr("Weather Service"), Translation.tr("Cannot find a GPS service. Using the fallback method instead."), "-a", "Shell"]);
                console.error("[WeatherService] Could not acquire a valid backend plugin.");
            }
        }
    }

    Timer {
        running: !root.gpsActive
        repeat: true
        interval: root.fetchInterval
        triggeredOnStart: !root.gpsActive
        onTriggered: root.getData()
    }
}
