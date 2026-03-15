import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

StyledPopup {
    id: root

    property bool alarmsActive: false
    open: alarmsActive || popupHovered
    signal closeRequested

    Item {
        id: content
        implicitWidth: 300
        implicitHeight: Math.min(mainCol.implicitHeight + 16, 480)
        clip: true

        ColumnLayout {
            id: mainCol
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: 0 }
            spacing: 6

            StyledPopupHeaderRow {
                Layout.fillWidth: true
                icon: "alarm"
                label: Translation.tr("Alarms")
                count: AlarmService.alarms.filter(a => !a.fired).length
            }

            // Add alarm card
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: addCol.implicitHeight + 14
                radius: Appearance.rounding.small
                color: Appearance.m3colors.m3surfaceContainerHigh
                border.width: 1
                border.color: Qt.rgba(Appearance.colors.colPrimary.r, Appearance.colors.colPrimary.g, Appearance.colors.colPrimary.b, 0.20)

                ColumnLayout {
                    id: addCol
                    anchors { fill: parent; leftMargin: 10; rightMargin: 10; topMargin: 7; bottomMargin: 7 }
                    spacing: 6

                    StyledText {
                        text: Translation.tr("New alarm")
                        font.pixelSize: Appearance.font.pixelSize.small
                        font.weight: Font.Medium
                        color: Appearance.colors.colPrimary
                    }

                    MaterialTextField {
                        id: labelInput
                        Layout.fillWidth: true
                        placeholderText: Translation.tr("Label (e.g. Take meds)")
                    }

                    RowLayout {
                        spacing: 6
                        MaterialTextField {
                            id: timeInput
                            Layout.fillWidth: true
                            placeholderText: "HH:MM"
                            maximumLength: 5
                            inputMethodHints: Qt.ImhDigitsOnly

                            Keys.onReturnPressed: addAlarmButton.addAlarm()
                        }
                        CircleUtilButton {
                            id: addAlarmButton
                            implicitWidth: 28; implicitHeight: 28
                            enabled: labelInput.text.trim().length > 0 && /^\d{1,2}:\d{2}$/.test(timeInput.text.trim())

                            function addAlarm() {
                                if (!enabled) return
                                const parts = timeInput.text.trim().split(":")
                                const h = Math.min(23, Math.max(0, parseInt(parts[0]) || 0))
                                const m = Math.min(59, Math.max(0, parseInt(parts[1]) || 0))
                                const now = new Date()
                                const target = new Date()
                                target.setHours(h, m, 0, 0)
                                if (target <= now) target.setDate(target.getDate() + 1)
                                AlarmService.addAlarm(labelInput.text.trim(), target.getTime())
                                labelInput.text = ""
                                timeInput.text = ""
                            }

                            onClicked: addAlarmButton.addAlarm()
                            MaterialSymbol {
                                anchors.centerIn: parent
                                text: "add_alarm"
                                iconSize: Appearance.font.pixelSize.large
                                color: Appearance.m3colors.m3onSurface
                            }
                        }
                    }
                }
            }

            // Alarm list
            Item {
                Layout.fillWidth: true
                implicitHeight: Math.min(alarmList.contentHeight + 2, 260)
                visible: AlarmService.alarms.length > 0
                clip: true

                ListView {
                    id: alarmList
                    anchors.fill: parent
                    model: AlarmService.alarms.slice().sort((a, b) => a.time - b.time)
                    spacing: 4
                    clip: true
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    delegate: Rectangle {
                        required property var modelData
                        required property int index
                        width: alarmList.width - 6
                        implicitHeight: alarmRow.implicitHeight + 10
                        radius: Appearance.rounding.small
                        color: Appearance.m3colors.m3surfaceContainerHigh
                        opacity: modelData.fired ? 0.5 : 1.0

                        RowLayout {
                            id: alarmRow
                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 8; rightMargin: 4 }
                            spacing: 6

                            MaterialSymbol {
                                text: modelData.fired ? "alarm_off" : "alarm_on"
                                iconSize: Appearance.font.pixelSize.normal
                                color: modelData.fired ? Appearance.colors.colSubtext : Appearance.colors.colPrimary
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 1
                                StyledText {
                                    text: modelData.label
                                    font.pixelSize: Appearance.font.pixelSize.small
                                    font.weight: Font.Medium
                                    color: Appearance.colors.colOnLayer1
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                StyledText {
                                    text: Qt.formatDateTime(new Date(modelData.time), "ddd hh:mm") + (modelData.fired ? " — " + Translation.tr("fired") : "")
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                    color: modelData.fired ? Appearance.colors.colSubtext : Appearance.m3colors.m3outline
                                }
                            }

                            CircleUtilButton {
                                implicitWidth: 22; implicitHeight: 22
                                onClicked: AlarmService.deleteAlarm(modelData.id)
                                MaterialSymbol {
                                    anchors.centerIn: parent
                                    text: "close"
                                    iconSize: Appearance.font.pixelSize.small
                                    color: Appearance.m3colors.m3onSurfaceVariant
                                }
                            }
                        }
                    }
                }
            }

            Item {
                Layout.fillWidth: true
                implicitHeight: 36
                visible: AlarmService.alarms.length === 0
                StyledText {
                    anchors.centerIn: parent
                    text: Translation.tr("No alarms set")
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.m3colors.m3outline
                }
            }
        }
    }
}
