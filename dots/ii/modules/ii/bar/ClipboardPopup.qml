import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

// Click-toggled clipboard history popup.
// Set clipboardActive to open/close from the parent button.
StyledPopup {
    id: root

    property bool clipboardActive: false
    open: clipboardActive || popupHovered

    signal closeRequested

    Item {
        id: content
        implicitWidth: 320
        implicitHeight: Math.min(mainCol.implicitHeight + 16, 420)
        clip: true

        ColumnLayout {
            id: mainCol
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: 0 }
            spacing: 6

            StyledPopupHeaderRow {
                Layout.fillWidth: true
                icon: "content_paste"
                label: Translation.tr("Clipboard")
                count: Cliphist.entries.length
            }

            // Scrollable entry list
            Item {
                Layout.fillWidth: true
                implicitHeight: Math.min(entryList.contentHeight + 2, 370)
                clip: true

                ListView {
                    id: entryList
                    anchors.fill: parent
                    model: Cliphist.entries
                    spacing: 4
                    clip: true

                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    delegate: Rectangle {
                        id: entryRow
                        required property string modelData
                        required property int index

                        width: entryList.width - 6
                        implicitHeight: entryContent.implicitHeight + 10
                        radius: Appearance.rounding.small
                        color: entryMouse.containsMouse
                            ? Appearance.m3colors.m3surfaceContainerHighest
                            : Appearance.m3colors.m3surfaceContainerHigh

                        Behavior on color { ColorAnimation { duration: 120 } }

                        readonly property bool isImage: Cliphist.entryIsImage(modelData)
                        readonly property string displayText: {
                            const txt = modelData.replace(/^\d+\t/, "")
                            return txt.length > 72 ? txt.substring(0, 69) + "…" : txt
                        }

                        RowLayout {
                            id: entryContent
                            anchors {
                                left: parent.left; right: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 8; rightMargin: 4
                            }
                            spacing: 6

                            Loader {
                                active: entryRow.isImage
                                visible: active
                                sourceComponent: CliphistImage {
                                    entry: entryRow.modelData
                                    maxWidth: 220
                                    maxHeight: 72
                                }
                            }

                            StyledText {
                                visible: !entryRow.isImage
                                Layout.fillWidth: true
                                text: entryRow.displayText
                                font.pixelSize: Appearance.font.pixelSize.small
                                wrapMode: Text.NoWrap
                                elide: Text.ElideRight
                                color: Appearance.colors.colOnLayer1
                            }

                            CircleUtilButton {
                                implicitHeight: 22
                                implicitWidth: 22
                                onClicked: Cliphist.deleteEntry(entryRow.modelData)
                                MaterialSymbol {
                                    text: "close"
                                    iconSize: Appearance.font.pixelSize.small
                                    color: Appearance.m3colors.m3onSurfaceVariant
                                }
                            }
                        }

                        MouseArea {
                            id: entryMouse
                            anchors { fill: parent; rightMargin: 26 }
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                Cliphist.copy(modelData)
                                root.closeRequested()
                            }
                        }
                    }
                }
            }
        }
    }
}
