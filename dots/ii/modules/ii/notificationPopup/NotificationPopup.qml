import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

// ── M3 motion tokens ─────────────────────────────────────────────────────────
// Emphasized easing:   cubic-bezier(0.2, 0, 0, 1)   — decelerate (enter)
// Emphasized easing:   cubic-bezier(0.3, 0, 1, 1)   — accelerate (exit)
// Duration — enter: 300 ms  |  exit: 200 ms  (M3 "medium" container transition)

Scope {
    id: notificationPopup

    // ── Toast notification popup ──────────────────────────────────────────────

    PanelWindow {
        id: root

        visible: (Notifications.popupList.length > 0) && !GlobalStates.screenLocked

        screen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? null

        WlrLayershell.namespace: "quickshell:notificationPopup"
        WlrLayershell.layer: WlrLayer.Overlay
        exclusiveZone: 0

        anchors {
            top: true
            right: true
            bottom: true
        }

        mask: Region {
            item: listview.contentItem
        }

        color: "transparent"

        implicitWidth: Appearance.sizes.notificationPopupWidth

        NotificationListView {
            id: listview

            anchors {
                top:    parent.top
                bottom: parent.bottom
                right:  parent.right
                rightMargin: 16
            }

            implicitWidth: parent.width - Appearance.sizes.elevationMargin * 2

            opacity: (Notifications.popupList.length > 0) ? 1.0 : 0.0

            Behavior on opacity {
                NumberAnimation {
                    duration: listview.opacity === 0.0 ? 200 : 300
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: listview.opacity === 0.0
                    ? [0.3, 0, 1, 1, 1, 1]
                    : [0.2, 0, 0, 1, 1, 1]
                }
            }

            property real slideOffset: (Notifications.popupList.length > 0) ? 0 : -24

            anchors.topMargin: 16 + slideOffset

            Behavior on slideOffset {
                NumberAnimation {
                    duration: (Notifications.popupList.length > 0) ? 300 : 200
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: (Notifications.popupList.length > 0)
                    ? [0.2, 0, 0, 1, 1, 1]
                    : [0.3, 0, 1, 1, 1, 1]
                }
            }

            popup: true
        }
    }

    // ── Inline reply popup ────────────────────────────────────────────────────
    // A separate PanelWindow anchored bottom-right so it is a first-class
    // Wayland input surface — no mask tricks required.
    // Triggered when any notification item calls Notifications.startReply(id).

    PanelWindow {
        id: replyPopupWindow

        visible: Notifications.replyingToId !== -1 && Notifications.replySource === "popup" && !GlobalStates.screenLocked

        screen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? null

        WlrLayershell.namespace: "quickshell:notificationReply"
        WlrLayershell.layer: WlrLayer.Overlay
        exclusiveZone: 0

        anchors {
            bottom: true
            right:  true
        }

        color: "transparent"

        implicitWidth: Appearance.sizes.notificationPopupWidth
        // Height driven by the reply bar's content + vertical margins
        implicitHeight: replyBarOuter.implicitHeight + 32

        // ── Slide-in animation (enter from below) ─────────────────────────────
        // The PanelWindow itself doesn't animate, so we animate the inner Item.

        Item {
            id: replyBarOuter
            anchors {
                left:        parent.left
                right:       parent.right
                bottom:      parent.bottom
                leftMargin:  Appearance.sizes.elevationMargin
                rightMargin: 16
            }
            implicitHeight: replyBarRect.implicitHeight

            opacity: replyPopupWindow.visible ? 1.0 : 0.0
            Behavior on opacity {
                NumberAnimation {
                    duration: replyBarOuter.opacity === 0.0 ? 200 : 300
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: replyBarOuter.opacity === 0.0
                    ? [0.3, 0, 1, 1, 1, 1]
                    : [0.2, 0, 0, 1, 1, 1]
                }
            }

            property real slideOffset: replyPopupWindow.visible ? 0 : 24
            anchors.bottomMargin: 16 + slideOffset
            Behavior on slideOffset {
                NumberAnimation {
                    duration: replyPopupWindow.visible ? 300 : 200
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: replyPopupWindow.visible
                    ? [0.2, 0, 0, 1, 1, 1]
                    : [0.3, 0, 1, 1, 1, 1]
                }
            }

            Rectangle {
                id: replyBarRect
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                implicitHeight: replyLayout.implicitHeight + 16
                height: implicitHeight

                radius: Appearance.rounding.normal
                color: Appearance.colors.colBackgroundSurfaceContainer
                border.color: Appearance.colors.colPrimary
                border.width: replyField.activeFocus ? 2 : 1

                Behavior on border.width {
                    NumberAnimation { duration: 100 }
                }

                ColumnLayout {
                    id: replyLayout
                    anchors {
                        left:            parent.left
                        right:           parent.right
                        verticalCenter:  parent.verticalCenter
                        leftMargin:      12
                        rightMargin:     8
                    }
                    spacing: 6

                    // "Replying to App · Summary" header row
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        Text {
                            text: "reply"
                            font.family: Appearance.font.family.icon
                            font.pixelSize: 14
                            color: Appearance.colors.colPrimary
                        }

                        Text {
                            Layout.fillWidth: true
                            text: {
                                const app     = Notifications.replyingToAppName;
                                const summary = Notifications.replyingToSummary;
                                const base    = app !== ""
                                ? Translation.tr("Replying to %1").arg(app)
                                : Translation.tr("Reply");
                                return summary !== "" ? base + " · " + summary : base;
                            }
                            font.pixelSize: Appearance.font.pixelSize.small
                            color: Appearance.colors.colSubtext
                            elide: Text.ElideRight
                        }

                        GroupButtonWithIcon {
                            buttonIcon: "close"
                            Layout.fillWidth: false
                            onClicked: Notifications.cancelReply()
                        }
                    }

                    // Text field + Send button row
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        TextField {
                            id: replyField
                            Layout.fillWidth: true
                            placeholderText: Translation.tr("Write a reply…")
                            font.pixelSize: Appearance.font.pixelSize.normal
                            color: Appearance.colors.colOnLayer2
                            leftPadding: 10
                            rightPadding: 10
                            topPadding: 6
                            bottomPadding: 6

                            background: Rectangle {
                                radius: Appearance.rounding.small
                                color: Appearance.colors.colLayer3
                            }

                            onVisibleChanged: {
                                if (visible) {
                                    text = "";
                                    forceActiveFocus();
                                }
                            }

                            Keys.onReturnPressed: (event) => {
                                if (!(event.modifiers & Qt.ShiftModifier))
                                    sendPopupReply();
                            }
                            Keys.onEscapePressed: Notifications.cancelReply()
                        }

                        GroupButtonWithIcon {
                            buttonIcon: "send"
                            Layout.fillWidth: false
                            enabled: replyField.text.trim().length > 0
                            onClicked: sendPopupReply()
                        }
                    }
                }
            }
        }

        function sendPopupReply() {
            Notifications.sendReply(Notifications.replyingToId, replyField.text);
        }
    }
}
