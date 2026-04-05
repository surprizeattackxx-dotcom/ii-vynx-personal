pragma Singleton
import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

Singleton {
    id: root

    // ── Desktop entry cache ───────────────────────────────────────────────
    property var _desktopEntryCache: ({})

    function getCachedDesktopEntry(appId) {
        if (!appId) return null
        if (_desktopEntryCache.hasOwnProperty(appId))
            return _desktopEntryCache[appId]
        const entry = DesktopEntries.heuristicLookup(appId)
        _desktopEntryCache[appId] = entry ?? null
        return _desktopEntryCache[appId]
    }

    function getCachedIcon(appId) {
        if (!appId) return ""
        const entry = getCachedDesktopEntry(appId)
        if (entry?.icon) return entry.icon
        return AppSearch.guessIcon(appId)
    }

    function invalidateDesktopEntryCache() {
        _desktopEntryCache = {}
    }

    Connections {
        target: DesktopEntries
        function onApplicationsChanged() { root.invalidateDesktopEntryCache() }
    }

    // ── App ID normalization ──────────────────────────────────────────────
    // Strips the .desktop suffix and lowercases for consistent comparisons
    function normalizeAppId(appId) {
        if (!appId) return ""
        let id = appId.toLowerCase().trim()
        if (id.endsWith(".desktop"))
            id = id.substring(0, id.length - 8)
        return id
    }

    // ── Pinned app helpers ────────────────────────────────────────────────
    function isPinned(appId) {
        if (!appId) return false
        const norm = normalizeAppId(appId)
        return Config.options.dock.pinnedApps.some(id => normalizeAppId(id) === norm)
    }

    function togglePin(appId) {
        if (!appId) return
        const norm = normalizeAppId(appId)
        const current = Config.options.dock.pinnedApps ?? []
        Config.options.dock.pinnedApps = isPinned(appId)
            ? current.filter(id => normalizeAppId(id) !== norm)
            : current.concat([appId])
    }

    function reorderPinnedApp(fromAppId, toAppId) {
        if (fromAppId === toAppId) return
        const pinned = Array.from(Config.options.dock.pinnedApps)
        const fromIdx = pinned.indexOf(fromAppId)
        const toIdx = pinned.indexOf(toAppId)
        if (fromIdx === -1 || toIdx === -1) return
        pinned.splice(toIdx, 0, pinned.splice(fromIdx, 1)[0])
        Config.options.dock.pinnedApps = pinned
    }

    // ── Pinned file helpers ───────────────────────────────────────────────
    function addPinnedFile(path) {
        const cleanPath = path.toString().replace(/^file:\/\//, "")
        const current = Config.options?.dock?.pinnedFiles ?? []
        if (current.includes(cleanPath)) return
        Config.options.dock.pinnedFiles = current.concat([cleanPath])
    }

    function removePinnedFile(path) {
        const cleanPath = path.toString().replace(/^file:\/\//, "")
        const current = Config.options?.dock?.pinnedFiles ?? []
        Config.options.dock.pinnedFiles = current.filter(p => p !== cleanPath)
    }

    function reorderPinnedFile(fromPath, toPath) {
        if (!fromPath || !toPath || fromPath === toPath) return
        const files = Array.from(Config.options?.dock?.pinnedFiles ?? [])
        const fromIdx = files.indexOf(fromPath)
        const toIdx = files.indexOf(toPath)
        if (fromIdx === -1 || toIdx === -1) return
        files.splice(toIdx, 0, files.splice(fromIdx, 1)[0])
        Config.options.dock.pinnedFiles = files
    }

    // ── Icon theme refresh ────────────────────────────────────────────────
    // Bumped several times after a theme change to force icon reload across the dock
    // TODO if loading the wallpaper takes too much time, the icons fail to change, i didn't find a better way
    property int iconThemeRevision: 0

    Timer {
        id: themeRefreshTimer
        interval: 300
        repeat: true
        property int count: 0
        onTriggered: {
            root.iconThemeRevision += 1
            if (++count >= 6) {
                count = 0
                stop()
            }
        }
    }

    property list<var> _prevApps: []
    property list<var> apps: {
        for (const old of root._prevApps)
            if (old) old.destroy();

        var map = new Map();

        const pinnedApps = Config.options?.dock.pinnedApps ?? [];
        for (const appId of pinnedApps) {
            if (appId) pinnedMap.set(appId, { pinned: true, toplevels: [] })
        }

        if (pinnedApps.length > 0) {
            map.set("SEPARATOR", { pinned: false, toplevels: [] });
        }

        const ignoredRegexStrings = Config.options?.dock.ignoredAppRegexes ?? [];
        const ignoredRegexes = ignoredRegexStrings.map(pattern => new RegExp(pattern, "i"));
        for (const toplevel of ToplevelManager.toplevels.values) {
            if (!toplevel?.appId) continue
            if (ignoredRegexes.some(re => re.test(toplevel.appId))) continue

            const normToplevel = normalizeAppId(toplevel.appId)
            let matchedKey = null
            for (const key of pinnedMap.keys()) {
                if (normalizeAppId(key) === normToplevel) { matchedKey = key; break }
            }

            if (matchedKey !== null) {
                pinnedMap.get(matchedKey).toplevels.push(toplevel)
            } else {
                const id = toplevel.appId
                if (!unpinnedMap.has(id))
                    unpinnedMap.set(id, { pinned: false, toplevels: [] })
                unpinnedMap.get(id).toplevels.push(toplevel)
            }
        }

        var values = [];

        for (const [key, value] of map) {
            values.push(appEntryComp.createObject(root, { appId: key, toplevels: value.toplevels, pinned: value.pinned }));
        }

        root._prevApps = values;
        return values;
    }

    component TaskbarAppEntry: QtObject {
        id: wrapper
        required property string appId
        required property list<var> toplevels
        required property bool pinned
    }
    Component {
        id: appEntryComp
        TaskbarAppEntry {}
    }
}
