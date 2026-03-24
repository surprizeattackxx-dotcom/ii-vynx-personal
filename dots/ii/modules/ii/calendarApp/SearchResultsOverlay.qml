import QtQuick
import QtQuick.Layouts
import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.services

Rectangle {
    id: root
    color: "transparent"

    property string searchQuery: ""
    property var searchResults: []

    signal eventClicked(var eventData)

    Timer {
        id: debounce
        interval: 300
        onTriggered: {
            root.searchResults = CalendarService.searchEvents(root.searchQuery);
        }
    }

    onSearchQueryChanged: debounce.restart()

    ColumnLayout {
        anchors.fill: parent
        spacing: 12

        // Header
        StyledText {
            text: {
                if (!root.searchQuery || root.searchQuery.length < 2)
                    return Translation.tr("Type to search events...");
                if (root.searchResults.length === 0)
                    return Translation.tr("No results for") + " \"" + root.searchQuery + "\"";
                return root.searchResults.length + " " + Translation.tr("results");
            }
            font.pixelSize: Appearance.font.pixelSize.normal
            font.weight: Font.DemiBold
            color: Appearance.m3colors.m3onSurface
        }

        // Results list
        StyledFlickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: width
            contentHeight: resultsColumn.implicitHeight

            ColumnLayout {
                id: resultsColumn
                width: parent.width
                spacing: 8

                Repeater {
                    model: root.searchResults

                    delegate: Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: resultContent.implicitHeight + 16
                        radius: Appearance.rounding.normal
                        color: resultHover.hovered
                            ? Appearance.m3colors.m3surfaceContainerHigh
                            : Appearance.m3colors.m3surfaceContainer

                        HoverHandler {
                            id: resultHover
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.eventClicked(modelData)
                        }

                        // Left accent bar
                        Rectangle {
                            width: 4
                            height: parent.height - 12
                            anchors.left: parent.left
                            anchors.leftMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            radius: 2
                            color: modelData.color
                        }

                        ColumnLayout {
                            id: resultContent
                            anchors.left: parent.left
                            anchors.leftMargin: 20
                            anchors.right: parent.right
                            anchors.rightMargin: 12
                            anchors.top: parent.top
                            anchors.topMargin: 8
                            spacing: 2

                            StyledText {
                                text: modelData.content
                                font.pixelSize: Appearance.font.pixelSize.normal
                                font.weight: Font.DemiBold
                                color: Appearance.m3colors.m3onSurface
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }

                            RowLayout {
                                spacing: 6
                                MaterialSymbol {
                                    text: "schedule"
                                    iconSize: 13
                                    color: Appearance.m3colors.m3onSurfaceVariant
                                }
                                StyledText {
                                    text: Qt.formatDateTime(modelData.startDate, "ddd, MMM d  h:mm AP")
                                          + " – " + Qt.formatDateTime(modelData.endDate, "h:mm AP")
                                    font.pixelSize: Appearance.font.pixelSize.small
                                    color: Appearance.m3colors.m3onSurfaceVariant
                                }
                            }

                            StyledText {
                                text: modelData.description
                                font.pixelSize: Appearance.font.pixelSize.small
                                color: Appearance.m3colors.m3onSurfaceVariant
                                visible: modelData.description && modelData.description.length > 0
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                        }
                    }
                }
            }
        }
    }
}
