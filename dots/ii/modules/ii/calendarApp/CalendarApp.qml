import qs
import qs.services
import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

Scope {
    id: root

    PanelWindow {
        id: panelWindow
        visible: GlobalStates.calendarAppOpen

        function hide() {
            GlobalStates.calendarAppOpen = false;
        }

        exclusiveZone: 0
        WlrLayershell.namespace: "quickshell:calendarApp"
        WlrLayershell.keyboardFocus: GlobalStates.calendarAppOpen ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        color: "transparent"

        anchors {
            top: true
            left: true
            right: true
            bottom: true
        }

        onVisibleChanged: {
            if (visible) {
                GlobalFocusGrab.addDismissable(panelWindow);
            } else {
                GlobalFocusGrab.removeDismissable(panelWindow);
            }
        }

        Connections {
            target: GlobalFocusGrab
            function onDismissed() {
                panelWindow.hide();
            }
        }

        // Click-to-dismiss background scrim
        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.3)

            MouseArea {
                anchors.fill: parent
                onClicked: panelWindow.hide()
            }
        }

        // Centered calendar card
        Loader {
            id: contentLoader
            active: GlobalStates.calendarAppOpen
            anchors.centerIn: parent
            width: Math.min(860, parent.width - 80)
            height: Math.min(640, parent.height - 80)

            sourceComponent: CalendarAppContent {
                onCloseRequested: panelWindow.hide()
            }
        }

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) {
                panelWindow.hide();
            }
        }
    }

    IpcHandler {
        target: "calendarApp"

        function toggle(): void {
            GlobalStates.calendarAppOpen = !GlobalStates.calendarAppOpen;
        }

        function close(): void {
            GlobalStates.calendarAppOpen = false;
        }

        function open(): void {
            GlobalStates.calendarAppOpen = true;
        }
    }

    GlobalShortcut {
        name: "calendarAppToggle"
        description: "Toggles calendar app on press"
        onPressed: {
            GlobalStates.calendarAppOpen = !GlobalStates.calendarAppOpen;
        }
    }
}
