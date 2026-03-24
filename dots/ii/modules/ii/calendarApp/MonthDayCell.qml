import QtQuick
import QtQuick.Layouts
import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.services

RippleButton {
    id: root

    property int day: 0
    property int isToday: 0  // -1 = other month, 0 = this month, 1 = today
    property bool isSelected: false
    property var taskList: []
    property date cellDate: new Date()
    property int spanBarCount: 0 // reserved space for multi-day span bars

    // Quick-create state
    property bool quickCreateMode: false
    property bool _clickPending: false

    // Drag-drop highlight
    property bool dropHighlight: false

    signal cellClicked(date cellDate)

    downAction: () => {
        if (root.isToday !== -1) {
            if (root._clickPending) {
                root._clickPending = false;
                doubleClickTimer.stop();
                root.quickCreateMode = true;
            } else {
                root._clickPending = true;
                doubleClickTimer.restart();
                root.cellClicked(root.cellDate);
            }
        }
    }

    // Weather: match cell date to forecast index
    property var weatherData: {
        if (root.isToday === -1) return null;
        const today = new Date();
        today.setHours(0, 0, 0, 0);
        const cell = new Date(root.cellDate);
        cell.setHours(0, 0, 0, 0);
        const dayOffset = Math.round((cell.getTime() - today.getTime()) / 86400000);
        if (dayOffset < 0 || dayOffset >= Weather.forecast.length) return null;
        return Weather.forecast[dayOffset];
    }

    buttonRadius: Appearance.rounding.small + 2
    toggled: isToday === 1
    enabled: isToday !== -1

    opacity: isToday === -1 ? 0.35 : 1.0

    Behavior on opacity {
        animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
    }

    // Selected state ring
    Rectangle {
        anchors.fill: parent
        radius: root.buttonRadius
        color: "transparent"
        border.width: root.isSelected && root.isToday !== 1 ? 2 : 0
        border.color: Appearance.m3colors.m3primary
        visible: root.isSelected && root.isToday !== 1
    }

    // Drop highlight (drag-to-reschedule)
    Rectangle {
        anchors.fill: parent
        radius: root.buttonRadius
        color: "transparent"
        border.width: root.dropHighlight ? 2 : 0
        border.color: Appearance.m3colors.m3tertiary
        visible: root.dropHighlight
        z: 5
    }

    // Double-click timer for quick create
    Timer {
        id: doubleClickTimer
        interval: 250
        onTriggered: {
            root._clickPending = false;
            // Single click — normal behavior, handled by parent
        }
    }

    contentItem: Item {
        // Weather icon (top-right)
        MaterialSymbol {
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: 2
            anchors.rightMargin: 2
            visible: root.weatherData !== null
            text: root.weatherData ? (Icons.getWeatherIcon(root.weatherData.wCode) ?? "cloud") : ""
            fill: 0
            iconSize: 11
            color: Appearance.m3colors.m3onSurfaceVariant
            opacity: 0.7
        }

        // Day number
        StyledText {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: root.taskList.length > 0 ? -4 - root.spanBarCount * 4 : 0
            text: root.day
            font.pixelSize: Appearance.font.pixelSize.normal
            font.weight: root.isToday === 1 ? Font.Bold : (root.isSelected ? Font.DemiBold : Font.Normal)
            color: root.isToday === 1 ? Appearance.m3colors.m3onPrimary
                 : root.isSelected ? Appearance.m3colors.m3primary
                 : Appearance.m3colors.m3onSurface
            horizontalAlignment: Text.AlignHCenter
            visible: !root.quickCreateMode
        }

        // Quick create text field
        Loader {
            anchors.fill: parent
            anchors.margins: 2
            active: root.quickCreateMode

            sourceComponent: MaterialTextField {
                placeholderText: Translation.tr("New event")
                font.pixelSize: Appearance.font.pixelSize.smallest
                Component.onCompleted: forceActiveFocus()

                Keys.onReturnPressed: {
                    if (text.trim().length > 0) {
                        CalendarService.quickCreateEvent(text.trim(), root.cellDate);
                    }
                    root.quickCreateMode = false;
                }
                Keys.onEscapePressed: root.quickCreateMode = false;
                onFocusChanged: {
                    if (!focus) root.quickCreateMode = false;
                }
            }
        }

        // Event dots row
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 4
            spacing: 3
            visible: root.taskList.length > 0 && root.isToday !== -1 && !root.quickCreateMode

            Repeater {
                model: Math.min(root.taskList.length, 3)

                delegate: Rectangle {
                    width: 5
                    height: 5
                    radius: 2.5
                    color: root.taskList[index] ? root.taskList[index].color
                         : Appearance.m3colors.m3primary
                }
            }
        }
    }
}
