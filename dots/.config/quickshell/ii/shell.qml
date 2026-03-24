//@ pragma UseQApplication
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Default
//@ pragma Env QT_QUICK_FLICKABLE_WHEEL_DECELERATION=10000
//@ pragma Env QT_SCALE_FACTOR=1

import QtQuick
import QtQuick.Window
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.3
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

import "modules/common"
import "services"
import "panelFamilies"
import "./modules/ii"

ShellRoot {
    id: root

    Process { id: applyProcess }

    Process {
        id: listProcess
        running: true
        command: [Quickshell.env("HOME") + "/.config/hypr/scripts/Animations.sh", "list"]
        stdout: StdioCollector {
            id: animListStdout
            onStreamFinished: {
                const raw = animListStdout.text.trim()
                if (!raw)
                    return
                presetsModel.clear()
                raw.split("\n").forEach(line => {
                    const name = line.trim()
                    if (name.length > 0)
                        presetsModel.append({ "name": name })
                })
            }
        }
    }

    ListModel { id: presetsModel }

    property string searchQuery: ""
    property string activePreset: ""

    function applyAnimation(preset) {
        applyProcess.command = [Quickshell.env("HOME") + "/.config/hypr/scripts/Animations.sh", "apply", preset]
        applyProcess.running = true
        root.activePreset = preset
        animationsWindow.visible = false
    }

    FloatingWindow {
        id: animationsWindow
        implicitWidth: 480
        implicitHeight: 580
        color: "transparent"
        visible: false

        screen: Quickshell.screens[0]

        onVisibleChanged: {
            if (visible) {
                const targetScreen = Quickshell.screens[0]
                animationsWindow.x = (targetScreen.geometry.width - implicitWidth) / 2
                animationsWindow.y = (targetScreen.geometry.height - implicitHeight) / 2
                searchField.text = ""
            }
        }

        Rectangle {
            id: windowRect
            anchors.fill: parent
            color: "#1d2021"
            radius: 12
            opacity: 1

            // Thin orange border
            Rectangle {
                anchors.fill: parent
                color: "transparent"
                radius: parent.radius
                border.color: "#d79921"
                border.width: 1
                opacity: 0.5
                z: 10
            }

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                // --- Header ---
                Rectangle {
                    Layout.fillWidth: true
                    height: 54
                    color: "#282828"
                    radius: 12
                    Rectangle {
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: 12
                        color: "#282828"
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 18
                        anchors.rightMargin: 12
                        spacing: 10

                        Rectangle { width: 4; height: 22; radius: 2; color: "#d79921" }

                        Text {
                            text: "Animations"
                            font.pixelSize: 16
                            font.weight: Font.DemiBold
                            color: "#ebdbb2"
                            Layout.fillWidth: true
                        }

                        Text {
                            text: presetsModel.count + " presets"
                            font.pixelSize: 11
                            color: "#928374"
                        }

                        Rectangle {
                            width: 28; height: 28; radius: 6
                            color: closeMa.containsMouse ? "#cc241d" : "#3c3836"
                            Behavior on color { ColorAnimation { duration: 120 } }
                            Text { anchors.centerIn: parent; text: "✕"; color: "#ebdbb2"; font.pixelSize: 13 }
                            MouseArea {
                                id: closeMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: animationsWindow.visible = false
                            }
                        }
                    }
                }

                // --- Search ---
                Rectangle {
                    Layout.fillWidth: true
                    Layout.topMargin: 12
                    Layout.leftMargin: 14
                    Layout.rightMargin: 14
                    height: 38
                    radius: 8
                    color: "#32302f"
                    border.color: searchField.activeFocus ? "#d79921" : "#3c3836"
                    border.width: 1
                    Behavior on border.color { ColorAnimation { duration: 150 } }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 10
                        spacing: 8

                        Text {
                            text: "⌕"
                            font.pixelSize: 16
                            color: searchField.activeFocus ? "#d79921" : "#928374"
                            Behavior on color { ColorAnimation { duration: 150 } }
                        }

                        TextInput {
                            id: searchField
                            Layout.fillWidth: true
                            color: "#ebdbb2"
                            font.pixelSize: 13
                            selectionColor: "#d79921"
                            selectedTextColor: "#1d2021"
                            clip: true
                            onTextChanged: root.searchQuery = text.toLowerCase()

                            Text {
                                anchors.fill: parent
                                text: "Search presets..."
                                color: "#928374"
                                font.pixelSize: 13
                                visible: !searchField.text && !searchField.activeFocus
                            }
                        }

                        Text {
                            text: "✕"
                            font.pixelSize: 11
                            color: "#928374"
                            visible: searchField.text.length > 0
                            MouseArea {
                                anchors.fill: parent
                                onClicked: searchField.text = ""
                                cursorShape: Qt.PointingHandCursor
                            }
                        }
                    }
                }

                // --- List ---
                ScrollView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.topMargin: 10
                    Layout.leftMargin: 14
                    Layout.rightMargin: 14
                    Layout.bottomMargin: 14
                    clip: true
                    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

                    ListView {
                        id: presetsList
                        model: presetsModel
                        spacing: 5
                        clip: true

                        delegate: Item {
                            width: presetsList.width
                            height: visible ? 46 : 0
                            visible: root.searchQuery === "" || model.name.toLowerCase().indexOf(root.searchQuery) !== -1
                            clip: true
                            Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                            Rectangle {
                                id: card
                                anchors.fill: parent
                                radius: 7
                                color: root.activePreset === model.name ? "#2a2215" : (cardMa.containsMouse ? "#3c3836" : "#32302f")
                                border.color: root.activePreset === model.name ? "#d79921" : (cardMa.containsMouse ? "#fe8019" : "transparent")
                                border.width: 1
                                Behavior on color { ColorAnimation { duration: 110 } }
                                Behavior on border.color { ColorAnimation { duration: 110 } }

                                Rectangle {
                                    width: 3; height: 22; radius: 2
                                    anchors.left: parent.left
                                    anchors.leftMargin: 1
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: "#d79921"
                                    visible: root.activePreset === model.name
                                }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: root.activePreset === model.name ? 16 : 14
                                    anchors.rightMargin: 14
                                    Behavior on anchors.leftMargin { NumberAnimation { duration: 120 } }

                                    Text {
                                        text: model.name
                                        color: root.activePreset === model.name ? "#d79921" : (cardMa.containsMouse ? "#ebdbb2" : "#d5c4a1")
                                        font.pixelSize: 13
                                        font.weight: root.activePreset === model.name ? Font.DemiBold : Font.Normal
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                        Behavior on color { ColorAnimation { duration: 110 } }
                                    }

                                    Text {
                                        text: root.activePreset === model.name ? "✓ active" : (cardMa.containsMouse ? "apply →" : "")
                                        color: root.activePreset === model.name ? "#b8bb26" : "#fe8019"
                                        font.pixelSize: 11
                                        opacity: (root.activePreset === model.name || cardMa.containsMouse) ? 1 : 0
                                        Behavior on opacity { NumberAnimation { duration: 100 } }
                                    }
                                }

                                Rectangle {
                                    id: rippleRect
                                    anchors.centerIn: parent
                                    width: 0; height: 0
                                    radius: width / 2
                                    color: "#d79921"
                                    opacity: 0
                                    SequentialAnimation {
                                        id: ripple
                                        ParallelAnimation {
                                            NumberAnimation { target: rippleRect; property: "width"; from: 0; to: card.width * 2; duration: 350; easing.type: Easing.OutCubic }
                                            NumberAnimation { target: rippleRect; property: "height"; from: 0; to: card.width * 2; duration: 350; easing.type: Easing.OutCubic }
                                            NumberAnimation { target: rippleRect; property: "opacity"; from: 0.3; to: 0; duration: 350 }
                                        }
                                    }
                                }

                                MouseArea {
                                    id: cardMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: { ripple.restart(); applyAnimation(model.name) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // --- Panel Family Logic ---
    property list<string> families: ["ii", "waffle"]
    function cyclePanelFamily() {
        const currentIndex = families.indexOf(Config.options.panelFamily)
        Config.options.panelFamily = families[(currentIndex + 1) % families.length]
    }

    component PanelFamilyLoader: LazyLoader {
        required property string identifier
        active: Config.ready && Config.options.panelFamily === identifier
    }

    PanelFamilyLoader { identifier: "ii"; component: IllogicalImpulseFamily {} }
    PanelFamilyLoader { identifier: "waffle"; component: WaffleFamily {} }

    IpcHandler { target: "panelFamily"; function cycle(): void { root.cyclePanelFamily() } }
    IpcHandler {
        target: "animations"
        function toggle(): void { animationsWindow.visible = !animationsWindow.visible }
        function open(): void { animationsWindow.visible = true }
        function close(): void { animationsWindow.visible = false }
    }

    GlobalShortcut { name: "panelFamilyCycle"; onPressed: root.cyclePanelFamily() }
}
