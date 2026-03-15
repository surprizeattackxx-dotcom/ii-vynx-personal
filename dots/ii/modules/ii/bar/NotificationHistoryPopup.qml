import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts
import Quickshell

StyledPopup {
    id: root

    property bool historyActive: false
    open: historyActive || popupHovered
    signal closeRequested

    Item {
        id: content
        implicitWidth: 320
        implicitHeight: Math.min(mainCol.implicitHeight + 16, 480)
        clip: true

        function timeAgo(epochMs) {
            const diff = Date.now() - epochMs
            const m = Math.floor(diff / 60000)
            if (m < 1)  return Translation.tr("just now")
            if (m < 60) return m + Translation.tr("m ago")
            const h = Math.floor(m / 60)
            if (h < 24) return h + Translation.tr("h ago")
            return Math.floor(h / 24) + Translation.tr("d ago")
        }

        ColumnLayout {
            id: mainCol
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: 0 }
            spacing: 6

            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                StyledPopupHeaderRow {
                    Layout.fillWidth: true
                    icon: "history"
                    label: Translation.tr("Notifications")
                    count: Notifications.list.length
                }
                CircleUtilButton {
                    visible: Notifications.list.length > 0
                    implicitWidth: 28; implicitHeight: 28
                    onClicked: Notifications.discardAllNotifications()
                    MaterialSymbol {
                        anchors.centerIn: parent
                        text: "delete_sweep"
                        iconSize: Appearance.font.pixelSize.large
                        color: Appearance.m3colors.m3onSurface
                    }
                }
            }

            Item {
                Layout.fillWidth: true
                implicitHeight: Math.min(notifList.contentHeight + 2, 400)
                visible: Notifications.list.length > 0
                clip: true

                ListView {
                    id: notifList
                    anchors.fill: parent
                    model: {
                        const sorted = Notifications.list.slice()
                        sorted.sort((a, b) => b.time - a.time)
                        return sorted
                    }
                    spacing: 4
                    clip: true
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    delegate: Rectangle {
                        required property var modelData
                        required property int index
                        width: notifList.width - 6
                        implicitHeight: notifCol.implicitHeight + 10
                        radius: Appearance.rounding.small
                        color: Appearance.m3colors.m3surfaceContainerHigh
                        border.width: 1
                        border.color: modelData.urgency === "critical"
                            ? Qt.rgba(Appearance.colors.colError.r, Appearance.colors.colError.g, Appearance.colors.colError.b, 0.30)
                            : Qt.rgba(Appearance.colors.colPrimary.r, Appearance.colors.colPrimary.g, Appearance.colors.colPrimary.b, 0.10)

                        ColumnLayout {
                            id: notifCol
                            anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 8; rightMargin: 4; topMargin: 5 }
                            spacing: 2

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 5
                                StyledText {
                                    text: modelData.appName
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                    font.weight: Font.Medium
                                    color: Appearance.colors.colPrimary
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                }
                                StyledText {
                                    text: content.timeAgo(modelData.time)
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                    color: Appearance.m3colors.m3outline
                                }
                                CircleUtilButton {
                                    implicitWidth: 18; implicitHeight: 18
                                    onClicked: Notifications.discardNotification(modelData.notificationId)
                                    MaterialSymbol {
                                        anchors.centerIn: parent
                                        text: "close"
                                        iconSize: Appearance.font.pixelSize.smallest
                                        color: Appearance.m3colors.m3onSurfaceVariant
                                    }
                                }
                            }
                            StyledText {
                                visible: modelData.summary.length > 0
                                text: modelData.summary
                                font.pixelSize: Appearance.font.pixelSize.small
                                font.weight: Font.Medium
                                color: Appearance.colors.colOnLayer1
                                wrapMode: Text.NoWrap
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                            StyledText {
                                visible: modelData.body.length > 0
                                bottomPadding: 5
                                text: modelData.body.length > 120 ? modelData.body.substring(0, 117) + "…" : modelData.body
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: Appearance.colors.colSubtext
                                wrapMode: Text.Wrap
                                Layout.fillWidth: true
                            }
                        }
                    }
                }
            }

            Item {
                Layout.fillWidth: true
                implicitHeight: 36
                visible: Notifications.list.length === 0
                StyledText {
                    anchors.centerIn: parent
                    text: Translation.tr("No notifications")
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.m3colors.m3outline
                }
            }
        }
    }
}
