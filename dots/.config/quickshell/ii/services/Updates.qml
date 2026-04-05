pragma Singleton
import qs.modules.common
import qs.modules.common.functions
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property bool available: false
    property bool checking: false
    property int count: 0
    property var packages: []

    readonly property bool updateAdvised: count > Config.options.updates.adviseUpdateThreshold
    readonly property bool updateStronglyAdvised: count > Config.options.updates.stronglyAdviseUpdateThreshold

    function load() {}
    function refresh() {
        // If already running, stop it first so we get a clean restart
        if (fetcher.running) {
            fetcher.running = false
        }
        root.checking = true
        fetcher.command[2] = "{ /usr/bin/checkupdates 2>/dev/null; flatpak remote-ls --updates 2>/dev/null | sed 's/\\t/ /g'; } | grep -v '^$'; true"
        fetcher.running = true
    }

    Timer {
        interval: 10 * 60 * 1000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Process {
        id: fetcher
        command: ["bash", "-c", ""]
        onRunningChanged: {
            if (!running) root.checking = false
        }
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = text.trim().split("\n").filter(l => l.trim() !== "")
                // Always update — empty output means zero updates, not "ignore"
                root.packages = lines
                root.count    = lines.length
                root.available = true
            }
        }
    }
}
