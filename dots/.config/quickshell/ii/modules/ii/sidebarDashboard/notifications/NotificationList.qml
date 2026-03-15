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
        anchors.bottom: statusRow.top
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
            buttonIcon: "smart_toy"
            enabled: Notifications.list.length > 0 && Config.options.policies.ai !== 0
            onClicked: () => {
                const digest = Notifications.list.map(n =>
                    `[${n.appName}] ${n.summary}${n.body.length > 0 ? ": " + n.body : ""}`
                ).join("\n");
                Ai.sendUserMessage(Translation.tr("Please summarize these notifications concisely:\n") + digest);
                GlobalStates.policiesPanelOpen = true;
                Persistent.states.sidebar.policies.tab = 0;
            }
        }
        GroupButtonWithIcon {
            Layout.fillWidth: false
            buttonIcon: "delete_sweep"
            onClicked: () => {
                Notifications.discardAllNotifications()
            }
        }
    }
}