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

    // Guard to prevent getData() firing before Config is ready
    property bool ready: false
    property string weatherApiKey: ""

    onUseUSCSChanged: { if (root.ready) root.getData(); }
    onCityChanged:    { if (root.ready) root.getData(); }
    onWeatherApiKeyChanged: { if (root.ready && root.weatherApiKey) root.getData(); }

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

    // alerts: list of { event } — generated from current conditions
    property var alerts: []

    function generateAlerts(current) {
        const newAlerts = []
        const windMs    = current?.wind?.speed  || 0
        const tempC     = current?.main?.temp   || 0
        const uvi       = root.data.uv          || 0
        const wCode     = root.data.wCode

        const windKmh = windMs * 3.6
        if (windKmh >= 50) {
            const windStr = root.useUSCS
            ? (windMs * 2.23694).toFixed(1) + " mph"
            : windKmh.toFixed(1) + " km/h"
            newAlerts.push({ event: Translation.tr("Wind Advisory") + " — " + windStr })
        }

        if (tempC >= 35) {
            const tStr = root.useUSCS ? Math.round(tempC * 9/5 + 32) + "°F" : Math.round(tempC) + "°C"
            newAlerts.push({ event: Translation.tr("Heat Advisory") + " — " + tStr })
        } else if (tempC <= -10) {
            const tStr = root.useUSCS ? Math.round(tempC * 9/5 + 32) + "°F" : Math.round(tempC) + "°C"
            newAlerts.push({ event: Translation.tr("Freeze Warning") + " — " + tStr })
        }

        if (uvi >= 8)     newAlerts.push({ event: Translation.tr("High UV Index") + " — " + uvi })
            if (wCode === 389) newAlerts.push({ event: Translation.tr("Thunderstorm Warning") })
                if (wCode === 338) newAlerts.push({ event: Translation.tr("Winter Storm Warning") })

                    root.alerts = newAlerts
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function degreesToWindDir(deg) {
        const dirs = ["N","NNE","NE","ENE","E","ESE","SE","SSE","S","SSW","SW","WSW","W","WNW","NW","NNW"];
        return dirs[Math.round(deg / 22.5) % 16];
    }

    function formatUnixTime(unix) {
        const d = new Date(unix * 1000);
        return d.getHours().toString().padStart(2,"0") + ":" + d.getMinutes().toString().padStart(2,"0");
    }

    function formatUnixDate(unix) {
        const d = new Date(unix * 1000);
        const days = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];
        return days[d.getDay()];
    }

    function owmIdToWCode(id) {
        if (id >= 200 && id < 300) return 389;
        if (id >= 300 && id < 400) return 266;
        if (id >= 500 && id < 510) return 308;
        if (id === 511)            return 329;
        if (id >= 520 && id < 600) return 308;
        if (id >= 600 && id < 700) return 338;
        if (id >= 700 && id < 800) return 143;
        if (id === 800)            return 113;
        if (id === 801)            return 116;
        if (id === 802)            return 119;
        return 122;
    }

    function cToF(c) { return Math.round(c * 9/5 + 32); }

    // ── Current weather ───────────────────────────────────────────────────────

    function refineData(current, uvi) {
        let temp = {};
        const windSpeedMs = current?.wind?.speed  || 0;
        const windDeg     = current?.wind?.deg     || 0;
        const humidityRaw = current?.main?.humidity || 0;
        const visibM      = current?.visibility    || 0;
        const pressHpa    = current?.main?.pressure || 0;
        const precipMM    = current?.rain?.["1h"] ?? current?.snow?.["1h"] ?? 0;

        temp.uv          = Math.round(uvi ?? 0);
        temp.humidity    = humidityRaw + "%";
        temp.windDir     = degreesToWindDir(windDeg);
        temp.wCode       = owmIdToWCode(current?.weather?.[0]?.id ?? 800);
        temp.city        = current?.name || "City";
        temp.description = current?.weather?.[0]?.description || "";
        temp.cloudCover  = (current?.clouds?.all ?? 0) + "%";

        temp.sunrise = formatUnixTime(current?.sys?.sunrise || 0);
        temp.sunset  = formatUnixTime(current?.sys?.sunset  || 0);

        // Note: dew_point is not available from /data/2.5/weather — always blank
        temp.dewPoint = "";

        if (root.useUSCS) {
            temp.wind          = (windSpeedMs * 2.23694).toFixed(1) + " mph";
            temp.precip        = (precipMM / 25.4).toFixed(2) + " in";
            temp.visib         = (visibM / 1609.34).toFixed(1) + " mi";
            temp.press         = (pressHpa * 0.02953).toFixed(2) + " inHg";
            temp.temp          = cToF(current?.main?.temp       ?? 0) + "°F";
            temp.tempFeelsLike = cToF(current?.main?.feels_like ?? 0) + "°F";
            temp.tempMin       = cToF(current?.main?.temp_min   ?? 0) + "°F";
            temp.tempMax       = cToF(current?.main?.temp_max   ?? 0) + "°F";
        } else {
            temp.wind          = (windSpeedMs * 3.6).toFixed(1) + " km/h";
            temp.precip        = precipMM.toFixed(1) + " mm";
            temp.visib         = (visibM / 1000).toFixed(1) + " km";
            temp.press         = pressHpa + " hPa";
            temp.temp          = Math.round(current?.main?.temp       ?? 0) + "°C";
            temp.tempFeelsLike = Math.round(current?.main?.feels_like ?? 0) + "°C";
            temp.tempMin       = Math.round(current?.main?.temp_min   ?? 0) + "°C";
            temp.tempMax       = Math.round(current?.main?.temp_max   ?? 0) + "°C";
        }

        temp.lastRefresh = DateTime.time + " • " + DateTime.date;
        root.data = temp;
        root.generateAlerts(current);
    }

    // ── 5-day forecast ────────────────────────────────────────────────────────
    // /forecast returns 3-hourly slots. We collapse them into one entry per day
    // by grouping on the date string, then picking min/max temp and the most
    // common condition id for that day.

    function refineForecast(forecastData) {
        const list = forecastData?.list ?? [];
        const byDay = {};
        const order = [];
        const todayStr = new Date().toISOString().slice(0, 10);

        for (const slot of list) {
            const d = new Date(slot.dt * 1000);
            const key = d.toISOString().slice(0, 10);
            if (key === todayStr) continue;
            if (!byDay[key]) {
                byDay[key] = { dt: slot.dt, mins: [], maxs: [], ids: [], descs: [] };
                order.push(key);
            }
            byDay[key].mins.push(slot.main?.temp_min ?? slot.main?.temp ?? 0);
            byDay[key].maxs.push(slot.main?.temp_max ?? slot.main?.temp ?? 0);
            byDay[key].ids.push(slot.weather?.[0]?.id ?? 800);
            byDay[key].descs.push(slot.weather?.[0]?.description || "");
        }

        const unit = root.useUSCS ? "°F" : "°C";
        const days = order.slice(0, 5).map(key => {
            const g = byDay[key];
            const rawMin = Math.min(...g.mins);
            const rawMax = Math.max(...g.maxs);
            // most frequent condition id
            const freq = {};
            let bestId  = g.ids[0];
            let bestN   = 0;
            let bestIdx = 0;
            for (let i = 0; i < g.ids.length; i++) {
                const id = g.ids[i];
                freq[id] = (freq[id] || 0) + 1;
                if (freq[id] > bestN) { bestN = freq[id]; bestId = id; bestIdx = i; }
            }
            const tMin = root.useUSCS ? cToF(rawMin) : Math.round(rawMin);
            const tMax = root.useUSCS ? cToF(rawMax) : Math.round(rawMax);
            return {
                dayLabel:    formatUnixDate(g.dt),
                                           wCode:       owmIdToWCode(bestId),
                                           tempMin:     tMin + unit,
                                           tempMax:     tMax + unit,
                                           description: g.descs[bestIdx] || "",
            };
        });
        root.forecast = days;
    }

    // ── Fetch ─────────────────────────────────────────────────────────────────

    function getData() {
        const apiKey  = root.weatherApiKey;
        if (!apiKey) return;
        const base    = "https://api.openweathermap.org/data/2.5";
        const units   = "metric";

        let weatherUrl  = "";
        let forecastUrl = "";
        let uviUrl      = "";

        if (root.gpsActive && root.location.valid) {
            const lat = root.location.lat;
            const lon = root.location.lon;  // fixed: was .long
            weatherUrl  = `${base}/weather?lat=${lat}&lon=${lon}&units=${units}&appid=${apiKey}`;
            forecastUrl = `${base}/forecast?lat=${lat}&lon=${lon}&units=${units}&appid=${apiKey}`;
            uviUrl      = `${base}/uvi?lat=${lat}&lon=${lon}&appid=${apiKey}`;
        } else {
            const q     = formatCityName(root.city);
            weatherUrl  = `${base}/weather?q=${q}&units=${units}&appid=${apiKey}`;
            forecastUrl = `${base}/forecast?q=${q}&units=${units}&appid=${apiKey}`;
        }

        let command;
        if (root.gpsActive && root.location.valid) {
            command = `
            W=$(curl -sf '${weatherUrl}') &&
            F=$(curl -sf '${forecastUrl}') &&
            U=$(curl -sf '${uviUrl}' | jq '.value // 0') &&
            echo "$W" | jq --argjson uvi "$U" --argjson fc "$F" \
            '{weather: ., uvi: $uvi, forecast: $fc}'
            `;
        } else {
            command = `
            W=$(curl -sf '${weatherUrl}') &&
            F=$(curl -sf '${forecastUrl}') &&
            LAT=$(echo "$W" | jq '.coord.lat') &&
            LON=$(echo "$W" | jq '.coord.lon') &&
            U=$(curl -sf '${base}/uvi?lat='"$LAT"'&lon='"$LON"'&appid=${apiKey}' | jq '.value // 0') &&
            echo "$W" | jq --argjson uvi "$U" --argjson fc "$F" \
            '{weather: ., uvi: $uvi, forecast: $fc}'
            `;
        }

        // Stop any in-flight request before reassigning command
        if (fetcher.running) fetcher.stop();

        // Full assignment so QML detects the change (index mutation won't notify)
        fetcher.command = ["bash", "-c", command];

        root.isLoading = true;
        root.hasError  = false;
        fetcher.running = true;
    }

    function formatCityName(cityName) {
        return cityName.trim().split(/\s+/).join('+');
    }

    // ── QML objects ───────────────────────────────────────────────────────────

    Process {
        id: apiKeyReader
        running: true
        command: ["bash", "-c", "cat ~/.config/illogical-impulse/weather_api_key 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                const key = this.text.trim();
                if (key) root.weatherApiKey = key;
            }
        }
    }

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
                    const parsedData = JSON.parse(text);
                    root.refineData(parsedData.weather, parsedData.uvi);
                    root.refineForecast(parsedData.forecast);
                    // alerts: parsedData.alerts would be populated here if using One Call 3.0
                    // root.alerts = parsedData.alerts ?? [];
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
                root.location.lon   = position.coordinate.longitude;  // fixed: was .long
                root.location.valid = true;
                root.getData();
            } else {
                root.gpsActive = root.location.valid;  // simplified ternary
                console.error("[WeatherService] Failed to get the GPS location.");
            }
        }

        onValidityChanged: {
            if (!positionSource.valid) {
                positionSource.stop();
                root.location.valid = false;
                root.gpsActive = false;
                // Kick off a city-based fetch now that GPS has been disabled
                root.getData();
                Quickshell.execDetached(["notify-send", Translation.tr("Weather Service"), Translation.tr("Cannot find a GPS service. Using the fallback method instead."), "-a", "Shell"]);
                console.error("[WeatherService] Could not acquire a valid backend plugin.");  // fixed: aquire → acquire
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
