pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io

// Each alarm: { id: string, label: string, time: number (epoch ms), fired: bool }
Singleton {
    id: root
    property var filePath: Directories.alarmsPath
    property list<var> alarms: []

    function addAlarm(label, timeMs) {
        const alarm = { id: Date.now().toString(), label: label, time: timeMs, fired: false }
        alarms = [...alarms, alarm]
        save()
    }

    function deleteAlarm(id) {
        alarms = alarms.filter(a => a.id !== id)
        save()
    }

    function save() { fileView.setText(JSON.stringify(alarms)) }

    Timer {
        interval: 15000
        repeat: true
        running: true
        onTriggered: {
            const now = Date.now()
            let changed = false
            root.alarms = root.alarms.map(alarm => {
                if (!alarm.fired && alarm.time <= now) {
                    Quickshell.execDetached(["notify-send", "-u", "critical", "-a", "Alarm",
                        "⏰ " + alarm.label, Qt.formatDateTime(new Date(alarm.time), "hh:mm")])
                    changed = true
                    return Object.assign({}, alarm, { fired: true })
                }
                return alarm
            })
            if (changed) root.save()
        }
    }

    FileView {
        id: fileView
        path: Qt.resolvedUrl(root.filePath)
        onLoaded: {
            try { root.alarms = JSON.parse(fileView.text()) } catch(e) { root.alarms = [] }
        }
        onLoadFailed: (error) => {
            if (error == FileViewError.FileNotFound) { root.alarms = []; fileView.setText("[]") }
        }
    }
    Component.onCompleted: fileView.reload()
}
