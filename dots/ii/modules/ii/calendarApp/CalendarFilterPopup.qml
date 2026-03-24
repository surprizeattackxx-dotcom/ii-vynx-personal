import QtQuick
import QtQuick.Layouts
import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.services

Rectangle {
    id: root

    property bool show: false

    width: 280
    height: Math.min(filterColumn.implicitHeight + 24, 400)
    radius: Appearance.rounding.normal
    color: Appearance.m3colors.m3surfaceContainer
    border.width: 1
    border.color: Appearance.m3colors.m3outlineVariant
    visible: root.show
    z: 50

    // Shadow
    layer.enabled: true
    layer.effect: null

    ColumnLayout {
        id: filterColumn
        anchors.fill: parent
        anchors.margins: 12
        spacing: 4

        StyledText {
            text: Translation.tr("Calendars")
            font.pixelSize: Appearance.font.pixelSize.normal
            font.weight: Font.DemiBold
            color: Appearance.m3colors.m3onSurface
            Layout.bottomMargin: 4
        }

        Repeater {
            model: CalendarService.calendarList

            delegate: RowLayout {
                Layout.fillWidth: true
                spacing: 10

                // Calendar color indicator
                Rectangle {
                    width: 14
                    height: 14
                    radius: 7
                    color: modelData.backgroundColor || Appearance.m3colors.m3primary
                }

                // Calendar name
                StyledText {
                    text: modelData.calendarSummary
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.m3colors.m3onSurface
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }

                // Toggle switch
                StyledSwitch {
                    checked: !CalendarService.hiddenCalendars.includes(modelData.calendarId)
                    onClicked: CalendarService.toggleCalendar(modelData.calendarId)
                }
            }
        }

        // Empty state
        StyledText {
            visible: CalendarService.calendarList.length === 0
            text: Translation.tr("No calendars found")
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.m3colors.m3onSurfaceVariant
        }
    }

    // Click outside to close
    MouseArea {
        parent: root.parent
        anchors.fill: parent
        visible: root.show
        z: root.z - 1
        onClicked: root.show = false
    }
}
