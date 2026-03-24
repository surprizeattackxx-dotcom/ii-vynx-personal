import QtQuick
import QtQuick.Layouts
import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.services

Rectangle {
    id: root

    property string eventTitle: ""
    property date eventStart
    property date eventEnd
    property color eventColor: Appearance.m3colors.m3primary
    property string eventDescription: ""
    property string eventId: ""
    property string calendarId: ""
    property string accountName: ""
    property string source: "khal"
    property bool expanded: false
    property string selfResponseStatus: "none"
    property var attendees: []

    signal editRequested()
    signal deleteRequested()
    signal dragStarted(var eventData)

    implicitHeight: cardContent.implicitHeight + 20
    radius: Appearance.rounding.normal + 2
    color: hoverHandler.hovered
        ? Appearance.m3colors.m3surfaceContainerHigh
        : Appearance.m3colors.m3surfaceContainer
    border.width: 1
    border.color: Qt.rgba(root.eventColor.r, root.eventColor.g, root.eventColor.b, 0.3)

    Behavior on color {
        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
    }

    // Left accent bar
    Rectangle {
        id: accentBar
        width: 4
        height: parent.height - 12
        anchors.left: parent.left
        anchors.leftMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        radius: 2
        color: root.eventColor
    }

    // Delete button (hover-visible, gcal events only)
    RippleButton {
        id: deleteBtn
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 4
        anchors.rightMargin: 4
        implicitWidth: 28
        implicitHeight: 28
        buttonRadius: Appearance.rounding.full
        visible: hoverHandler.hovered && root.source === "gcal" && root.eventId !== ""
        z: 10

        contentItem: MaterialSymbol {
            text: "delete_outline"
            iconSize: 16
            horizontalAlignment: Text.AlignHCenter
            color: Appearance.m3colors.m3error
        }

        downAction: () => root.deleteRequested()
    }

    // Edit button (hover-visible, gcal events only)
    RippleButton {
        id: editBtn
        anchors.top: parent.top
        anchors.right: deleteBtn.left
        anchors.topMargin: 4
        anchors.rightMargin: 2
        implicitWidth: 28
        implicitHeight: 28
        buttonRadius: Appearance.rounding.full
        visible: hoverHandler.hovered && root.source === "gcal" && root.eventId !== ""
        z: 10

        contentItem: MaterialSymbol {
            text: "edit"
            iconSize: 16
            horizontalAlignment: Text.AlignHCenter
            color: Appearance.m3colors.m3onSurfaceVariant
        }

        downAction: () => root.editRequested()
    }

    HoverHandler {
        id: hoverHandler
    }

    // Press-and-hold for drag, click for expand
    MouseArea {
        anchors.fill: parent
        onClicked: {
            if (root.eventDescription.length > 0) {
                root.expanded = !root.expanded;
            }
        }
        onPressAndHold: {
            if (root.source === "gcal" && root.eventId !== "") {
                root.dragStarted({
                    content: root.eventTitle,
                    startDate: root.eventStart,
                    endDate: root.eventEnd,
                    description: root.eventDescription,
                    eventId: root.eventId,
                    calendarId: root.calendarId,
                    accountName: root.accountName,
                    source: root.source,
                    color: root.eventColor,
                });
            }
        }
    }

    ColumnLayout {
        id: cardContent
        anchors.left: accentBar.right
        anchors.leftMargin: 10
        anchors.right: parent.right
        anchors.rightMargin: 12
        anchors.top: parent.top
        anchors.topMargin: 10
        spacing: 4

        // Time
        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            MaterialSymbol {
                text: "schedule"
                iconSize: 14
                color: Appearance.m3colors.m3onSurfaceVariant
            }

            StyledText {
                text: Qt.formatDateTime(root.eventStart, Config.options.time.format)
                      + " – "
                      + Qt.formatDateTime(root.eventEnd, Config.options.time.format)
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.m3colors.m3onSurfaceVariant
            }
        }

        // Title
        StyledText {
            Layout.fillWidth: true
            text: root.eventTitle
            font.pixelSize: Appearance.font.pixelSize.normal
            font.weight: Font.DemiBold
            color: Appearance.m3colors.m3onSurface
            wrapMode: Text.Wrap
            elide: Text.ElideRight
            maximumLineCount: 2
        }

        // RSVP status row
        RowLayout {
            Layout.fillWidth: true
            spacing: 4
            visible: root.selfResponseStatus !== "none" && root.selfResponseStatus !== ""

            MaterialSymbol {
                text: root.selfResponseStatus === "accepted" ? "check_circle"
                    : root.selfResponseStatus === "declined" ? "cancel"
                    : root.selfResponseStatus === "tentative" ? "help"
                    : "pending"
                iconSize: 14
                color: root.selfResponseStatus === "accepted" ? Appearance.m3colors.m3primary
                     : root.selfResponseStatus === "declined" ? Appearance.m3colors.m3error
                     : Appearance.m3colors.m3onSurfaceVariant
            }

            StyledText {
                text: root.selfResponseStatus === "accepted" ? Translation.tr("Accepted")
                    : root.selfResponseStatus === "declined" ? Translation.tr("Declined")
                    : root.selfResponseStatus === "tentative" ? Translation.tr("Maybe")
                    : Translation.tr("Pending")
                font.pixelSize: Appearance.font.pixelSize.smallest
                color: Appearance.m3colors.m3onSurfaceVariant
            }

            Item { Layout.fillWidth: true }

            // RSVP action buttons (hover only)
            Row {
                spacing: 2
                visible: hoverHandler.hovered && root.source === "gcal"

                RippleButton {
                    implicitWidth: 22
                    implicitHeight: 22
                    buttonRadius: Appearance.rounding.full
                    downAction: () => CalendarService.rsvpEvent(root.eventId, root.calendarId, root.accountName, "accepted")

                    contentItem: MaterialSymbol {
                        text: "check"
                        iconSize: 14
                        horizontalAlignment: Text.AlignHCenter
                        color: Appearance.m3colors.m3primary
                    }

                    StyledToolTip { text: Translation.tr("Accept") }
                }

                RippleButton {
                    implicitWidth: 22
                    implicitHeight: 22
                    buttonRadius: Appearance.rounding.full
                    downAction: () => CalendarService.rsvpEvent(root.eventId, root.calendarId, root.accountName, "tentative")

                    contentItem: MaterialSymbol {
                        text: "question_mark"
                        iconSize: 14
                        horizontalAlignment: Text.AlignHCenter
                        color: Appearance.m3colors.m3onSurfaceVariant
                    }

                    StyledToolTip { text: Translation.tr("Maybe") }
                }

                RippleButton {
                    implicitWidth: 22
                    implicitHeight: 22
                    buttonRadius: Appearance.rounding.full
                    downAction: () => CalendarService.rsvpEvent(root.eventId, root.calendarId, root.accountName, "declined")

                    contentItem: MaterialSymbol {
                        text: "close"
                        iconSize: 14
                        horizontalAlignment: Text.AlignHCenter
                        color: Appearance.m3colors.m3error
                    }

                    StyledToolTip { text: Translation.tr("Decline") }
                }
            }
        }

        // Description (expandable)
        StyledText {
            Layout.fillWidth: true
            text: root.eventDescription
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.m3colors.m3onSurfaceVariant
            wrapMode: Text.Wrap
            visible: root.expanded && root.eventDescription.length > 0
            maximumLineCount: 4
            elide: Text.ElideRight
        }

        // Expand hint
        MaterialSymbol {
            Layout.alignment: Qt.AlignHCenter
            text: root.expanded ? "expand_less" : "expand_more"
            iconSize: 14
            color: Appearance.m3colors.m3outline
            visible: root.eventDescription.length > 0
        }
    }
}
