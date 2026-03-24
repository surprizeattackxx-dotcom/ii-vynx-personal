import QtQuick
import QtQuick.Layouts
import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.services

Item {
    id: root

    property var todayEvents: CalendarService.getFilteredTasksByDate(new Date())
        .sort((a, b) => a.startDate - b.startDate)

    // Refresh every minute
    Timer {
        interval: 60000
        running: true
        repeat: true
        onTriggered: root.todayEvents = CalendarService.getFilteredTasksByDate(new Date())
            .sort((a, b) => a.startDate - b.startDate)
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 6

        // Header
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            StyledText {
                text: Translation.tr("Today")
                font.pixelSize: Appearance.font.pixelSize.larger
                font.weight: Font.Bold
                color: Appearance.m3colors.m3onSurface
            }

            Item { Layout.fillWidth: true }

            StyledText {
                text: new Date().toLocaleDateString(Qt.locale(), "MMM d")
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.m3colors.m3onSurfaceVariant
            }
        }

        // Event count
        StyledText {
            text: {
                const count = root.todayEvents.length;
                if (count === 0) return Translation.tr("No events today");
                if (count === 1) return "1 " + Translation.tr("event");
                return count + " " + Translation.tr("events");
            }
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.m3colors.m3onSurfaceVariant
        }

        // Separator
        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: Appearance.m3colors.m3outlineVariant
        }

        // Event list
        StyledFlickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: width
            contentHeight: agendaColumn.implicitHeight

            ColumnLayout {
                id: agendaColumn
                width: parent.width
                spacing: 4

                // Empty state
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 30
                    spacing: 8
                    visible: root.todayEvents.length === 0

                    MaterialSymbol {
                        Layout.alignment: Qt.AlignHCenter
                        text: "event_available"
                        iconSize: 36
                        color: Appearance.m3colors.m3outlineVariant
                    }

                    StyledText {
                        Layout.alignment: Qt.AlignHCenter
                        text: Translation.tr("Nothing scheduled")
                        color: Appearance.m3colors.m3onSurfaceVariant
                        font.pixelSize: Appearance.font.pixelSize.small
                    }
                }

                // Event rows
                Repeater {
                    model: root.todayEvents

                    delegate: Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: eventRow.implicitHeight + 10
                        radius: Appearance.rounding.small
                        color: eventHover.hovered
                            ? Appearance.m3colors.m3surfaceContainerHighest
                            : "transparent"

                        HoverHandler {
                            id: eventHover
                        }

                        RowLayout {
                            id: eventRow
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 4
                            anchors.rightMargin: 4
                            spacing: 8

                            // Time
                            StyledText {
                                text: Qt.formatDateTime(modelData.startDate, "h:mm AP")
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                font.family: "monospace"
                                color: Appearance.m3colors.m3onSurfaceVariant
                                Layout.preferredWidth: 36
                            }

                            // Color dot
                            Rectangle {
                                width: 8
                                height: 8
                                radius: 4
                                color: modelData.color
                            }

                            // Title
                            StyledText {
                                text: modelData.content
                                font.pixelSize: Appearance.font.pixelSize.small
                                color: Appearance.m3colors.m3onSurface
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }
                        }
                    }
                }
            }
        }

        // Open Calendar button
        RippleButton {
            Layout.fillWidth: true
            Layout.preferredHeight: 32
            buttonRadius: Appearance.rounding.normal

            contentItem: RowLayout {
                spacing: 6
                Item { Layout.fillWidth: true }
                MaterialSymbol {
                    text: "open_in_new"
                    iconSize: 14
                    color: Appearance.m3colors.m3primary
                }
                StyledText {
                    text: Translation.tr("Open Calendar")
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.m3colors.m3primary
                    font.weight: Font.DemiBold
                }
                Item { Layout.fillWidth: true }
            }

            downAction: () => { GlobalStates.calendarAppOpen = true; }
        }
    }
}
