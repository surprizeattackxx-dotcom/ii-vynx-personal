import qs.modules.common
import qs.modules.common.widgets
import qs.services
import Qt5Compat.GraphicalEffects
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root

    NotificationListView { // Scrollable window
        id: listview
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: replyBarContainer.top
        anchors.bottomMargin: 5

        clip: true
        layer.enabled: true
        layer.effect: OpacityMask {
            maskSource: Rectangle {
                width: listview.width
                height: listview.height
                radius: Appearance.rounding.normal
            }
        }

        popup: false
    }

    // Placeholder when list is empty
    PagePlaceholder {
        shown: Notifications.list.length === 0
        icon: "notifications_active"
        description: Translation.tr("Nothing")
        shape: MaterialShape.Shape.Ghostish
        descriptionHorizontalAlignment: Text.AlignHCenter
    }

    // ── Inline reply bar ──────────────────────────────────────────────────────
    // Slides up from above the status row when a notification reply is started.
    // Notification item delegates trigger this via Notifications.startReply(id).

    Item {
        id: replyBarContainer
        anchors {
            left: parent.left
            right: parent.right
            bottom: statusRow.top
            bottomMargin: active ? 5 : 0
        }

        readonly property bool active: Notifications.replyingToId !== -1 && Notifications.replySource === "sidebar"
        height: active ? replyBarContent.implicitHeight + 16 : 0
        clip: true

        Behavior on height {
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
        }

        Rectangle {
            id: replyBarContent
            anchors {
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            implicitHeight: replyLayout.implicitHeight + 16
            height: implicitHeight
            radius: Appearance.rounding.normal
            color: Appearance.colors.colLayer2
            border.color: Appearance.colors.colPrimary
            border.width: replyField.activeFocus ? 2 : 1

            Behavior on border.width {
                NumberAnimation { duration: 100 }
            }

            ColumnLayout {
                id: replyLayout
                anchors {
                    left: parent.left
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                    leftMargin: 12
                    rightMargin: 8
                }
                spacing: 6

                // "Replying to App · Summary" header row
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    Text {
                        text: "reply"
                        font.family: Appearance.font.family.iconMaterial
                        font.pixelSize: 14
                        color: Appearance.colors.colPrimary
                    }

                    Text {
                        Layout.fillWidth: true
                        text: {
                            const app = Notifications.replyingToAppName;
                            const summary = Notifications.replyingToSummary;
                            const base = app !== "" ? Translation.tr("Replying to %1").arg(app) : Translation.tr("Reply");
                            return summary !== "" ? base + " · " + summary : base;
                        }
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: Appearance.colors.colSubtext
                        elide: Text.ElideRight
                    }

                    // Cancel button — reuses GroupButtonWithIcon which is a known type
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

                        // Focus and clear on each new reply session
                        onVisibleChanged: {
                            if (visible) {
                                text = "";
                                forceActiveFocus();
                            }
                        }

                        Keys.onReturnPressed: (event) => {
                            if (!(event.modifiers & Qt.ShiftModifier))
                                root.sendReply();
                        }
                        Keys.onEscapePressed: Notifications.cancelReply()
                    }

                    GroupButtonWithIcon {
                        buttonIcon: "send"
                        Layout.fillWidth: false
                        enabled: replyField.text.trim().length > 0
                        onClicked: root.sendReply()
                    }
                }
            }
        }
    }

    // ── Status / action row ───────────────────────────────────────────────────

    ButtonGroup {
        id: statusRow
        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
        }

        GroupButtonWithIcon {
            Layout.fillWidth: false
            buttonIcon: "notifications_paused"
            toggled: Notifications.silent
            onClicked: () => {
                Notifications.silent = !Notifications.silent;
            }
        }
        GroupButtonWithIcon {
            enabled: false
            Layout.fillWidth: true
            buttonText: Translation.tr("%1 notifications").arg(Notifications.list.length)
        }
        GroupButtonWithIcon {
            Layout.fillWidth: false
            buttonIcon: "delete_sweep"
            onClicked: () => {
                Notifications.discardAllNotifications()
            }
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function sendReply() {
        Notifications.sendReply(Notifications.replyingToId, replyField.text);
    }
}
