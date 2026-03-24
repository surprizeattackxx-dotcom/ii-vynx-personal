import QtQuick
import QtQuick.Layouts
import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.services

Rectangle {
    id: root
    color: Appearance.m3colors.m3surfaceContainerLow

    property date selectedDate: new Date()
    property var dayEvents: CalendarService.getFilteredTasksByDate(selectedDate)

    // Weather for selected day (only available for ~6 days ahead)
    property var weatherData: {
        const today = new Date();
        today.setHours(0, 0, 0, 0);
        const sel = new Date(selectedDate);
        sel.setHours(0, 0, 0, 0);
        const dayOffset = Math.round((sel.getTime() - today.getTime()) / 86400000);
        if (dayOffset < 0 || dayOffset >= Weather.forecast.length) return null;
        return Weather.forecast[dayOffset];
    }

    signal createEventRequested()
    signal editEventRequested(var eventData)
    signal deleteEventRequested(var eventData)
    signal dragStarted(var eventData)

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        // Day header
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            StyledText {
                text: root.selectedDate.toLocaleDateString(Qt.locale(), "dddd")
                font.pixelSize: Appearance.font.pixelSize.small
                font.weight: Font.DemiBold
                color: Appearance.m3colors.m3primary
                Layout.fillWidth: true
            }

            StyledText {
                text: root.selectedDate.toLocaleDateString(Qt.locale(), "MMMM d, yyyy")
                font.pixelSize: Appearance.font.pixelSize.larger + 2
                font.weight: Font.Bold
                color: Appearance.m3colors.m3onSurface
                Layout.fillWidth: true
            }

            // Event count
            StyledText {
                text: {
                    const count = root.dayEvents.length;
                    if (count === 0) return Translation.tr("No events");
                    if (count === 1) return "1 " + Translation.tr("event");
                    return count + " " + Translation.tr("events");
                }
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.m3colors.m3onSurfaceVariant
                Layout.fillWidth: true
            }
        }

        // Weather card (when forecast available)
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: weatherRow.implicitHeight + 16
            radius: Appearance.rounding.small
            color: Appearance.m3colors.m3surfaceContainer
            visible: root.weatherData !== null

            RowLayout {
                id: weatherRow
                anchors.fill: parent
                anchors.margins: 8
                spacing: 10

                MaterialSymbol {
                    text: root.weatherData ? (Icons.getWeatherIcon(root.weatherData.wCode) ?? "cloud") : ""
                    iconSize: 28
                    color: Appearance.m3colors.m3primary
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    StyledText {
                        text: root.weatherData ? (root.weatherData.description ?? "") : ""
                        font.pixelSize: Appearance.font.pixelSize.small
                        font.weight: Font.DemiBold
                        color: Appearance.m3colors.m3onSurface
                    }

                    RowLayout {
                        spacing: 8

                        RowLayout {
                            spacing: 3
                            MaterialSymbol {
                                text: "arrow_upward"
                                iconSize: 12
                                color: Appearance.m3colors.m3error
                            }
                            StyledText {
                                text: root.weatherData?.tempMax ?? ""
                                font.pixelSize: Appearance.font.pixelSize.small
                                font.weight: Font.DemiBold
                                color: Appearance.m3colors.m3onSurface
                            }
                        }

                        RowLayout {
                            spacing: 3
                            MaterialSymbol {
                                text: "arrow_downward"
                                iconSize: 12
                                color: Appearance.m3colors.m3tertiary
                            }
                            StyledText {
                                text: root.weatherData?.tempMin ?? ""
                                font.pixelSize: Appearance.font.pixelSize.small
                                color: Appearance.m3colors.m3onSurfaceVariant
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

        // Events list
        StyledFlickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: width
            contentHeight: eventsColumn.implicitHeight

            ColumnLayout {
                id: eventsColumn
                width: parent.width
                spacing: 8

                // No events placeholder
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 40
                    spacing: 8
                    visible: root.dayEvents.length === 0

                    MaterialSymbol {
                        Layout.alignment: Qt.AlignHCenter
                        text: "event_busy"
                        iconSize: 48
                        color: Appearance.m3colors.m3outlineVariant
                    }

                    StyledText {
                        Layout.alignment: Qt.AlignHCenter
                        text: Translation.tr("No events scheduled")
                        color: Appearance.m3colors.m3onSurfaceVariant
                        font.pixelSize: Appearance.font.pixelSize.normal
                    }
                }

                // Event cards
                Repeater {
                    model: root.dayEvents

                    delegate: EventCard {
                        Layout.fillWidth: true
                        eventTitle: modelData.content
                        eventStart: modelData.startDate
                        eventEnd: modelData.endDate
                        eventColor: modelData.color
                        eventDescription: modelData.description ?? ""
                        eventId: modelData.eventId ?? ""
                        calendarId: modelData.calendarId ?? ""
                        accountName: modelData.accountName ?? ""
                        source: modelData.source ?? "khal"
                        selfResponseStatus: modelData.selfResponseStatus ?? "none"
                        attendees: modelData.attendees ?? []

                        onEditRequested: root.editEventRequested(modelData)
                        onDeleteRequested: root.deleteEventRequested(modelData)
                        onDragStarted: (eventData) => root.dragStarted(eventData)
                    }
                }
            }
        }
    }

    // Floating Action Button — create new event
    FloatingActionButton {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: 16
        anchors.bottomMargin: 16
        iconText: "add"
        z: 10
        downAction: () => root.createEventRequested()
    }
}
