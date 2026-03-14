// WallpaperHistory.qml
// Scrollable wallpaper mood history strip.
// Reads from $XDG_STATE_HOME/quickshell/user/generated/wallpaper/history.json
// Each entry shows a thumbnail with dominant color dots underneath.
// Click any entry to re-apply that wallpaper via switchwall.sh.
//
// Usage — drop inside your bar or as a standalone Quickshell widget:
//   WallpaperHistory {}

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

Item {
    id: root

    // How many entries to show in the strip (history keeps 50, we show fewer)
    property int maxVisible: 12
    // Thumbnail dimensions
    property int thumbWidth:  72
    property int thumbHeight: 44
    property int thumbRadius: 10
    property int dotSize:     8
    property int spacing:     8

    implicitWidth:  (thumbWidth + spacing) * maxVisible
    implicitHeight: thumbHeight + dotSize + spacing * 3

    // -----------------------------------------------------------------------
    // History data — reloaded whenever the file changes
    // -----------------------------------------------------------------------
    property var entries: []

    FileView {
        id: historyFile
        path: StandardPaths.writableLocation(StandardPaths.GenericStateLocation)
              + "/quickshell/user/generated/wallpaper/history.json"
        onTextChanged: root.reloadHistory()
    }

    function reloadHistory() {
        try {
            var parsed = JSON.parse(historyFile.text)
            entries = parsed.slice(0, maxVisible)
        } catch (e) {
            entries = []
        }
    }

    Component.onCompleted: reloadHistory()

    // -----------------------------------------------------------------------
    // Re-apply process — runs switchwall.sh for the clicked entry
    // -----------------------------------------------------------------------
    property string pendingPath: ""
    property string pendingMode: ""

    Process {
        id: switchProc
        command: [
            "bash",
            StandardPaths.locate(StandardPaths.HomeLocation, "")
                + "/.config/quickshell/ii/scripts/../switchwall.sh",
            "--image", root.pendingPath,
            "--mode",  root.pendingMode
        ]
        running: false
    }

    function reapply(imgPath, mode) {
        pendingPath = imgPath
        pendingMode = mode || "dark"
        switchProc.running = true
    }

    // -----------------------------------------------------------------------
    // UI
    // -----------------------------------------------------------------------
    ScrollView {
        anchors.fill: parent
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy:   ScrollBar.AlwaysOff
        clip: true

        Row {
            spacing: root.spacing
            padding: root.spacing

            Repeater {
                model: root.entries

                delegate: Column {
                    spacing: 4
                    width: root.thumbWidth

                    // Thumbnail
                    Rectangle {
                        width:  root.thumbWidth
                        height: root.thumbHeight
                        radius: root.thumbRadius
                        color:  "transparent"
                        clip:   true

                        Image {
                            anchors.fill: parent
                            source:       "file://" + modelData.path
                            fillMode:     Image.PreserveAspectCrop
                            smooth:       true
                            asynchronous: true
                            layer.enabled: true

                            // Rounded clip via layer
                            layer.effect: null
                        }

                        // Hover overlay
                        Rectangle {
                            anchors.fill: parent
                            radius:       root.thumbRadius
                            color:        hoverArea.containsMouse
                                          ? Qt.rgba(0, 0, 0, 0.35)
                                          : "transparent"
                            Behavior on color { ColorAnimation { duration: 120 } }

                            // Re-apply icon on hover
                            Text {
                                anchors.centerIn: parent
                                text:    "↺"
                                font.pixelSize: 20
                                color:   "white"
                                visible: hoverArea.containsMouse
                            }
                        }

                        // Monitor badge (shown if more than one monitor's entries exist)
                        Rectangle {
                            anchors {
                                top:   parent.top
                                right: parent.right
                                margins: 3
                            }
                            width:  monitorLabel.implicitWidth + 6
                            height: 14
                            radius: 4
                            color:  Qt.rgba(0, 0, 0, 0.55)
                            visible: modelData.monitor !== ""

                            Text {
                                id: monitorLabel
                                anchors.centerIn: parent
                                text:    modelData.monitor
                                font.pixelSize: 8
                                color:   "white"
                            }
                        }

                        // Timestamp tooltip
                        ToolTip.visible: hoverArea.containsMouse
                        ToolTip.text:    modelData.timestamp
                                         ? Qt.formatDateTime(
                                             new Date(modelData.timestamp),
                                             "ddd d MMM · hh:mm"
                                           )
                                         : modelData.path

                        MouseArea {
                            id:          hoverArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape:  Qt.PointingHandCursor
                            onClicked:    root.reapply(modelData.path, modelData.mode)
                        }
                    }

                    // Dominant color dot
                    Rectangle {
                        width:  root.dotSize
                        height: root.dotSize
                        radius: root.dotSize / 2
                        color:  modelData.dominantColor || "#888888"
                        anchors.horizontalCenter: parent.horizontalCenter

                        // Subtle ring
                        Rectangle {
                            anchors.centerIn: parent
                            width:  parent.width  + 2
                            height: parent.height + 2
                            radius: (parent.width + 2) / 2
                            color:  "transparent"
                            border.color: Qt.rgba(1, 1, 1, 0.2)
                            border.width: 1
                            z: -1
                        }
                    }
                }
            }
        }
    }

    // Empty state
    Text {
        anchors.centerIn: parent
        text:    "No wallpaper history yet"
        color:   Qt.rgba(1, 1, 1, 0.4)
        font.pixelSize: 13
        visible: root.entries.length === 0
    }
}
