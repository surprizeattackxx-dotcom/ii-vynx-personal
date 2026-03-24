import qs.modules.common
import qs.modules.common.widgets
import qs.services
import Qt5Compat.GraphicalEffects
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root

    property bool showHistory: false

    function timeAgo(epochMs) {
        const diff = Date.now() - epochMs
        const m = Math.floor(diff / 60000)
        if (m < 1)  return Translation.tr("just now")
        if (m < 60) return m + Translation.tr("m ago")
        const h = Math.floor(m / 60)
        if (h < 24) return h + Translation.tr("h ago")
        return Math.floor(h / 24) + Translation.tr("d ago")
    }

    // Grouped live view
    NotificationListView {
        id: listview
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: replyBarContainer.top
        anchors.bottomMargin: 5
        visible: !root.showHistory
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

    // Flat chronological history view
    ListView {
        id: historyView
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: replyBarContainer.top
        anchors.bottomMargin: 5
        visible: root.showHistory
        clip: true
        spacing: 3
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        model: {
            const sorted = Notifications.list.slice()
            sorted.sort((a, b) => b.time - a.time)
            return sorted
        }

        delegate: Rectangle {
            required property var modelData
            required property int index
            width: historyView.width
            implicitHeight: histCol.implicitHeight + 10
            radius: Appearance.rounding.small
            color: Appearance.m3colors.m3surfaceContainerHigh
            border.width: 1
            border.color: modelData.urgency === "critical"
                ? Qt.rgba(Appearance.colors.colError.r, Appearance.colors.colError.g, Appearance.colors.colError.b, 0.30)
                : Qt.rgba(Appearance.colors.colPrimary.r, Appearance.colors.colPrimary.g, Appearance.colors.colPrimary.b, 0.10)

            ColumnLayout {
                id: histCol
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
                        text: root.timeAgo(modelData.time)
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.m3colors.m3outline
                    }
                    RippleButton {
                        implicitWidth: 18; implicitHeight: 18
                        buttonRadius: implicitWidth / 2
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
            buttonIcon: root.showHistory ? "notifications" : "history"
            toggled: root.showHistory
            onClicked: root.showHistory = !root.showHistory
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

    // ── Helpers ───────────────────────────────────────────────────────────────

    function sendReply() {
        Notifications.sendReply(Notifications.replyingToId, replyField.text);
    }
}
