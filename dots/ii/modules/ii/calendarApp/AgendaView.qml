import QtQuick
import QtQuick.Layouts
import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.services

Item {
    id: root

    property var weekEvents: CalendarService.eventsInWeek

    StyledFlickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: agendaColumn.implicitHeight

        ColumnLayout {
            id: agendaColumn
            width: parent.width
            spacing: 4

            // Header
            StyledText {
                text: Translation.tr("This Week")
                font.pixelSize: Appearance.font.pixelSize.larger + 2
                font.weight: Font.Bold
                color: Appearance.m3colors.m3onSurface
                Layout.fillWidth: true
                Layout.bottomMargin: 8
            }

            Repeater {
                model: root.weekEvents

                delegate: ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    // Day header
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: index > 0 ? 12 : 0
                        spacing: 8

                        Rectangle {
                            width: 4
                            height: 20
                            radius: 2
                            color: Appearance.m3colors.m3primary
                        }

                        StyledText {
                            text: modelData.name
                            font.pixelSize: Appearance.font.pixelSize.normal
                            font.weight: Font.DemiBold
                            color: Appearance.m3colors.m3onSurface
                        }

                        StyledText {
                            text: modelData.events.length === 0 ? Translation.tr("No events") : ""
                            font.pixelSize: Appearance.font.pixelSize.small
                            color: Appearance.m3colors.m3outline
                        }

                        Item { Layout.fillWidth: true }
                    }

                    // Events for this day
                    Repeater {
                        model: modelData.events

                        delegate: Rectangle {
                            Layout.fillWidth: true
                            Layout.leftMargin: 12
                            implicitHeight: agendaEventContent.implicitHeight + 16
                            radius: Appearance.rounding.normal
                            color: agendaEventHover.containsMouse
                                ? Appearance.m3colors.m3surfaceContainerHigh
                                : Appearance.m3colors.m3surfaceContainer

                            Behavior on color {
                                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                            }

                            // Left accent
                            Rectangle {
                                width: 4
                                height: parent.height - 8
                                anchors.left: parent.left
                                anchors.leftMargin: 4
                                anchors.verticalCenter: parent.verticalCenter
                                radius: 2
                                color: modelData.color
                            }

                            MouseArea {
                                id: agendaEventHover
                                anchors.fill: parent
                                hoverEnabled: true
                            }

                            RowLayout {
                                id: agendaEventContent
                                anchors.left: parent.left
                                anchors.leftMargin: 16
                                anchors.right: parent.right
                                anchors.rightMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 12

                                // Time column
                                ColumnLayout {
                                    spacing: 0
                                    Layout.minimumWidth: 50

                                    StyledText {
                                        text: modelData.start
                                        font.pixelSize: Appearance.font.pixelSize.small
                                        font.weight: Font.DemiBold
                                        color: Appearance.m3colors.m3onSurfaceVariant
                                    }

                                    StyledText {
                                        text: modelData.end
                                        font.pixelSize: Appearance.font.pixelSize.smaller
                                        color: Appearance.m3colors.m3outline
                                    }
                                }

                                // Title
                                StyledText {
                                    Layout.fillWidth: true
                                    text: modelData.title
                                    font.pixelSize: Appearance.font.pixelSize.normal
                                    color: Appearance.m3colors.m3onSurface
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }
                }
            }

            // Empty state
            ColumnLayout {
                Layout.fillWidth: true
                Layout.topMargin: 60
                spacing: 12
                visible: {
                    for (let i = 0; i < root.weekEvents.length; i++) {
                        if (root.weekEvents[i].events.length > 0) return false;
                    }
                    return true;
                }

                MaterialSymbol {
                    Layout.alignment: Qt.AlignHCenter
                    text: "event_available"
                    iconSize: 64
                    color: Appearance.m3colors.m3outlineVariant
                }

                StyledText {
                    Layout.alignment: Qt.AlignHCenter
                    text: Translation.tr("No events this week")
                    font.pixelSize: Appearance.font.pixelSize.larger
                    color: Appearance.m3colors.m3onSurfaceVariant
                }

                StyledText {
                    Layout.alignment: Qt.AlignHCenter
                    text: Translation.tr("Your schedule is clear")
                    font.pixelSize: Appearance.font.pixelSize.normal
                    color: Appearance.m3colors.m3outline
                }
            }
        }
    }
}
