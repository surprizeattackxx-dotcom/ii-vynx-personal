import QtQuick
import QtQuick.Layouts
import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.services

Item {
    id: root

    property date selectedDate: new Date()
    property date weekStart: {
        let d = new Date(selectedDate);
        const dayOfWeek = (d.getDay() - Config.options.time.firstDayOfWeek - 1 + 7) % 7;
        d.setDate(d.getDate() - dayOfWeek);
        d.setHours(0, 0, 0, 0);
        return d;
    }

    signal dateSelected(date date)
    signal createEventRequested(date date, int hour)
    signal editEventRequested(var eventData)
    signal deleteEventRequested(var eventData)

    readonly property int hourHeight: 60
    readonly property int gutterWidth: 50
    readonly property int headerHeight: 50

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Day headers
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: root.headerHeight
            spacing: 0

            // Gutter spacer
            Item {
                Layout.preferredWidth: root.gutterWidth
                Layout.fillHeight: true
            }

            Repeater {
                model: 7

                delegate: Rectangle {
                    required property int index
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    color: "transparent"

                    property date dayDate: {
                        let d = new Date(root.weekStart);
                        d.setDate(d.getDate() + index);
                        return d;
                    }
                    property bool isToday: {
                        const now = new Date();
                        return dayDate.getDate() === now.getDate() &&
                               dayDate.getMonth() === now.getMonth() &&
                               dayDate.getFullYear() === now.getFullYear();
                    }

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 2

                        StyledText {
                            text: dayDate.toLocaleDateString(Qt.locale(), "ddd")
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            font.weight: Font.Medium
                            color: isToday ? Appearance.m3colors.m3primary : Appearance.m3colors.m3onSurfaceVariant
                            Layout.alignment: Qt.AlignHCenter
                        }

                        Rectangle {
                            Layout.alignment: Qt.AlignHCenter
                            width: 28
                            height: 28
                            radius: 14
                            color: isToday ? Appearance.m3colors.m3primary : "transparent"

                            StyledText {
                                anchors.centerIn: parent
                                text: dayDate.getDate()
                                font.pixelSize: Appearance.font.pixelSize.normal
                                font.weight: isToday ? Font.Bold : Font.Normal
                                color: isToday ? Appearance.m3colors.m3onPrimary : Appearance.m3colors.m3onSurface
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: root.dateSelected(dayDate)
                            }
                        }
                    }
                }
            }
        }

        // Separator
        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: Appearance.m3colors.m3outlineVariant
        }

        // Scrollable time grid
        StyledFlickable {
            id: timeFlickable
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: width
            contentHeight: root.hourHeight * 24
            clip: true

            Component.onCompleted: {
                // Scroll to 7am on load
                contentY = Math.max(0, root.hourHeight * 7 - 20);
            }

            // Time grid background
            Item {
                width: parent.width
                height: root.hourHeight * 24

                // Hour rows
                Repeater {
                    model: 24

                    delegate: Item {
                        required property int index
                        y: index * root.hourHeight
                        width: parent.width
                        height: root.hourHeight

                        // Hour label in gutter
                        StyledText {
                            x: 8
                            y: -6
                            text: {
                                const h = index % 12;
                                const suffix = index >= 12 ? " PM" : " AM";
                                return (h === 0 ? "12" : h) + suffix;
                            }
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            color: Appearance.m3colors.m3onSurfaceVariant
                            visible: index > 0
                        }

                        // Grid line
                        Rectangle {
                            x: root.gutterWidth
                            width: parent.width - root.gutterWidth
                            height: 1
                            color: Appearance.m3colors.m3outlineVariant
                            opacity: 0.5
                        }
                    }
                }

                // Current time indicator
                Rectangle {
                    id: nowLine
                    x: root.gutterWidth - 6
                    width: parent.width - root.gutterWidth + 6
                    height: 2
                    color: Appearance.m3colors.m3error
                    radius: 1
                    z: 10

                    property real nowPosition: {
                        const now = new Date();
                        return now.getHours() * root.hourHeight + now.getMinutes() * root.hourHeight / 60;
                    }
                    y: nowPosition

                    // Red dot at start of line
                    Rectangle {
                        x: 0
                        y: -4
                        width: 10
                        height: 10
                        radius: 5
                        color: Appearance.m3colors.m3error
                    }

                    Timer {
                        interval: 60000
                        running: true
                        repeat: true
                        onTriggered: nowLine.nowPosition = Qt.binding(() => {
                            const now = new Date();
                            return now.getHours() * root.hourHeight + now.getMinutes() * root.hourHeight / 60;
                        })
                    }
                }

                // Day columns with events
                RowLayout {
                    x: root.gutterWidth
                    width: parent.width - root.gutterWidth
                    height: parent.height
                    spacing: 0

                    Repeater {
                        model: 7

                        delegate: Item {
                            required property int index
                            Layout.fillWidth: true
                            Layout.fillHeight: true

                            property date dayDate: {
                                let d = new Date(root.weekStart);
                                d.setDate(d.getDate() + index);
                                return d;
                            }
                            property var dayEvents: CalendarService.getFilteredTasksByDate(dayDate)

                            // Vertical separator
                            Rectangle {
                                x: 0
                                width: 1
                                height: parent.height
                                color: Appearance.m3colors.m3outlineVariant
                                opacity: 0.3
                            }

                            // Click to create event
                            MouseArea {
                                anchors.fill: parent
                                onDoubleClicked: (mouse) => {
                                    const hour = Math.floor(mouse.y / root.hourHeight);
                                    root.createEventRequested(dayDate, hour);
                                }
                            }

                            // Event blocks
                            Repeater {
                                model: dayEvents

                                delegate: Rectangle {
                                    required property var modelData
                                    required property int index

                                    readonly property real startMinutes: modelData.startDate.getHours() * 60 + modelData.startDate.getMinutes()
                                    readonly property real endMinutes: modelData.endDate.getHours() * 60 + modelData.endDate.getMinutes()
                                    readonly property real durationMinutes: Math.max(endMinutes - startMinutes, 20)

                                    x: 3
                                    y: startMinutes * root.hourHeight / 60
                                    width: parent.width - 6
                                    height: durationMinutes * root.hourHeight / 60
                                    radius: Appearance.rounding.small
                                    color: Qt.rgba(modelData.color.r, modelData.color.g, modelData.color.b, 0.25)
                                    border.width: 1
                                    border.color: Qt.rgba(modelData.color.r, modelData.color.g, modelData.color.b, 0.5)
                                    z: 5

                                    // Left accent
                                    Rectangle {
                                        width: 3
                                        height: parent.height
                                        color: modelData.color
                                        radius: parent.radius
                                    }

                                    ColumnLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: 8
                                        anchors.topMargin: 2
                                        anchors.rightMargin: 4
                                        spacing: 0

                                        StyledText {
                                            text: modelData.content
                                            font.pixelSize: Appearance.font.pixelSize.smallest
                                            font.weight: Font.DemiBold
                                            color: Appearance.m3colors.m3onSurface
                                            Layout.fillWidth: true
                                            elide: Text.ElideRight
                                        }

                                        StyledText {
                                            text: Qt.formatDateTime(modelData.startDate, "h:mm AP")
                                                  + " – " + Qt.formatDateTime(modelData.endDate, "h:mm AP")
                                            font.pixelSize: Appearance.font.pixelSize.smallest
                                            color: Appearance.m3colors.m3onSurfaceVariant
                                            visible: durationMinutes >= 40
                                        }
                                    }

                                    HoverHandler {
                                        id: blockHover
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: {
                                            root.dateSelected(modelData.startDate);
                                            root.editEventRequested(modelData);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
