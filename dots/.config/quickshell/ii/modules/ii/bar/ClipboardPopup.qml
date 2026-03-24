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
        implicitHeight: Math.min(mainCol.implicitHeight + 16, 480)
        clip: true

        readonly property bool showPinned: Config.options.bar.clipboard?.showPinned ?? true
        readonly property var pinnedEntries: Cliphist.entries.filter(e => PinnedClipboard.isPinned(e))

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

            // Pinned section
            Loader {
                active: content.showPinned && content.pinnedEntries.length > 0
                visible: active
                Layout.fillWidth: true
                sourceComponent: ColumnLayout {
                    spacing: 4
                    RowLayout {
                        spacing: 4
                        MaterialSymbol {
                            text: "push_pin"
                            iconSize: Appearance.font.pixelSize.small
                            color: Appearance.colors.colPrimary
                        }
                        StyledText {
                            text: Translation.tr("Pinned")
                            font.pixelSize: Appearance.font.pixelSize.small
                            font.weight: Font.Medium
                            color: Appearance.colors.colPrimary
                        }
                    }
                    Repeater {
                        model: content.pinnedEntries.slice(0, 8)
                        delegate: ClipEntryRow {
                            required property string modelData
                            required property int index
                            entry: modelData
                            entryIndex: index
                            width: parent?.width ?? 0
                            onEntryClicked: {
                                Cliphist.copy(modelData)
                                root.closeRequested()
                            }
                        }
                    }
                    Rectangle {
                        width: parent.width; height: 1
                        color: Qt.rgba(Appearance.colors.colPrimary.r, Appearance.colors.colPrimary.g, Appearance.colors.colPrimary.b, 0.12)
                    }
                }
            }

            // Scrollable entry list
            Item {
                Layout.fillWidth: true
                implicitHeight: Math.min(entryList.contentHeight + 2, content.showPinned && content.pinnedEntries.length > 0 ? 280 : 370)
                clip: true

                ListView {
                    id: entryList
                    anchors.fill: parent
                    model: Cliphist.entries
                    spacing: 4
                    clip: true

                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    delegate: ClipEntryRow {
                        required property string modelData
                        required property int index
                        entry: modelData
                        entryIndex: index
                        width: entryList.width - 6
                        onEntryClicked: {
                            Cliphist.copy(modelData)
                            root.closeRequested()
                        }
                    }
                }
            }
        }

        component ClipEntryRow: Rectangle {
            id: entryRow
            property string entry: ""
            property int entryIndex: 0
            signal entryClicked

            implicitHeight: entryContent.implicitHeight + 10
            radius: Appearance.rounding.small
            color: entryMouse.containsMouse
                ? Appearance.m3colors.m3surfaceContainerHighest
                : Appearance.m3colors.m3surfaceContainerHigh

            Behavior on color { ColorAnimation { duration: 120 } }

            readonly property bool isImage: Cliphist.entryIsImage(entry)
            readonly property string displayText: {
                const txt = entry.replace(/^\d+\t/, "")
                return txt.length > 72 ? txt.substring(0, 69) + "…" : txt
            }
            readonly property bool pinned: PinnedClipboard.isPinned(entry)

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
                        entry: entryRow.entry
                        maxWidth: 200
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
                    implicitHeight: 22; implicitWidth: 22
                    onClicked: PinnedClipboard.toggle(entryRow.entry)
                    MaterialSymbol {
                        text: "push_pin"
                        iconSize: Appearance.font.pixelSize.small
                        fill: entryRow.pinned ? 1 : 0
                        color: entryRow.pinned ? Appearance.colors.colPrimary : Appearance.m3colors.m3onSurfaceVariant
                    }
                }

                CircleUtilButton {
                    implicitHeight: 22; implicitWidth: 22
                    onClicked: Cliphist.deleteEntry(entryRow.entry)
                    MaterialSymbol {
                        text: "close"
                        iconSize: Appearance.font.pixelSize.small
                        color: Appearance.m3colors.m3onSurfaceVariant
                    }
                }
            }

            MouseArea {
                id: entryMouse
                anchors { fill: parent; rightMargin: 52 }
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: entryRow.entryClicked()
            }
        }
    }
}
