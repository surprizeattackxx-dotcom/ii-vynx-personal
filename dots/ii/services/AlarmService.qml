pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io

// Each alarm: { id, label, time (epoch ms), repeat: "none"|"daily"|"weekdays", fired: bool }
Singleton {
    id: root
    property var filePath: Directories.alarmsPath
    property list<var> alarms: []

    function addAlarm(label, timeMs, repeat) {
        const alarm = {
            id: Date.now().toString(),
            label: label,
            time: timeMs,
            repeat: repeat ?? "none",
            fired: false
        }
        alarms = [...alarms, alarm]
        save()
    }

    function deleteAlarm(id) {
        alarms = alarms.filter(a => a.id !== id)
        save()
    }

    function snoozeAlarm(id) {
        const alarm = alarms.find(a => a.id === id)
        if (!alarm) return
        addAlarm(alarm.label, Date.now() + 10 * 60 * 1000, alarm.repeat)
    }

    function _nextOccurrence(alarm) {
        const t = new Date(alarm.time)
        t.setDate(t.getDate() + 1)
        if (alarm.repeat === "weekdays") {
            while (t.getDay() === 0 || t.getDay() === 6)
                t.setDate(t.getDate() + 1)
        }
        return t.getTime()
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
                    notifProc.fire(alarm)
                    changed = true
                    if (alarm.repeat !== "none") {
                        return Object.assign({}, alarm, { time: root._nextOccurrence(alarm) })
                    }
                    return Object.assign({}, alarm, { fired: true })
                }
                return alarm
            })
            if (changed) root.save()
        }
    }

    // Fires alarm notification; listens for "snooze" action
    QtObject {
        id: notifProc

        function fire(alarm) {
            const proc = processComponent.createObject(root, { alarmData: alarm })
            proc.running = true
        }
    }

    component AlarmProcess: Process {
        id: self
        property var alarmData
        command: [
            "notify-send", "-u", "critical", "-a", "Alarm",
            "-A", "snooze=Snooze 10m",
            "⏰ " + alarmData.label,
            Qt.formatDateTime(new Date(alarmData.time), "hh:mm")
        ]
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                if (data.trim() === "snooze")
                    root.snoozeAlarm(self.alarmData.id)
            }
        }
        onExited: self.destroy()
    }

    property Component processComponent: AlarmProcess {}

    FileView {
        id: fileView
        path: Qt.resolvedUrl(root.filePath)
        onLoaded: {
            try {
                root.alarms = JSON.parse(fileView.text()).map(a => {
                    if (a.repeat === undefined) a.repeat = "none"
                    return a
                })
            } catch(e) { root.alarms = [] }
        }
        onLoadFailed: (error) => {
            if (error == FileViewError.FileNotFound) { root.alarms = []; fileView.setText("[]") }
        }
    }
    Component.onCompleted: fileView.reload()
}
