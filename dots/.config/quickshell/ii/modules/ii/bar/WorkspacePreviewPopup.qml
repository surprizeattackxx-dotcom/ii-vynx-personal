import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets

// Hover popup that lists the windows in the currently hovered workspace pill.
// Usage in Workspaces.qml:
//   WorkspacePreviewPopup {
//       hoverTarget: root
//       open: interactionMouseArea.containsMouse && windows.length > 0 || popupHovered
//       windows: <filtered window list for hovered workspace>
//   }
StyledPopup {
    id: root

    property var windows: []

    Item {
        id: content
        implicitWidth: Math.max(windowList.implicitWidth + 20, 100)
        implicitHeight: windowList.implicitHeight + 14

        ColumnLayout {
            id: windowList
            anchors.centerIn: parent
            spacing: 5

            Repeater {
                model: root.windows
                delegate: RowLayout {
                    required property var modelData
                    spacing: 8

                    IconImage {
                        source: Quickshell.iconPath(AppSearch.guessIcon(modelData?.class ?? ""), "image-missing")
                        implicitSize: 20
                    }

                    StyledText {
                        readonly property string raw: modelData?.title ?? modelData?.class ?? "?"
                        text: raw.length > 38 ? raw.substring(0, 35) + "…" : raw
                        font.pixelSize: Appearance.font.pixelSize.small
                        Layout.maximumWidth: 240
                    }
                }
            }
        }
    }
}
