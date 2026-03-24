import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Quickshell
import Quickshell.Io

Item {
    id: root
    width: 420
    height: 500

    property var presets: []

    Component.onCompleted: {
        Io.run({
            command: [
                Quickshell.env("HOME") + "/.config/hypr/scripts/Animations.sh",
                "list"
            ],
            onFinished: (res) => {
                presets = res.stdout.trim().split("\n").filter(s => s.trim().length > 0)
            }
        })
    }

    Rectangle {
        anchors.fill: parent
        radius: 14
        color: "#111111dd"
        border.color: "#2a2a2a"
        border.width: 1
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        Label {
            text: "Animations"
            font.pixelSize: 20
            font.weight: Font.DemiBold
            Layout.alignment: Qt.AlignHCenter
        }

        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            model: presets
            spacing: 6
            clip: true

            delegate: Rectangle {
                width: parent.width
                height: 42
                radius: 10

                property bool hovered: false

                color: hovered ? "#2a2a2a" : "#00000000"
                border.color: hovered ? "#3a3a3a" : "transparent"

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true

                    onEntered: parent.hovered = true
                    onExited: parent.hovered = false

                    onClicked: {
                        Io.run({
                            command: [
                                Quickshell.env("HOME") + "/.config/hypr/scripts/Animations.sh",
                                "apply",
                                modelData
                            ]
                        })
                    }
                }

                Text {
                    text: modelData
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: 14
                    color: "white"
                    font.pixelSize: 14
                }
            }
        }
    }
}
