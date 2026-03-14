import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland

LazyLoader {
    id: root
    property Item hoverTarget
    default property Item contentItem
    property real popupBackgroundMargin: 0

    // Defaults to showing when the hoverTarget is hovered.
    // Callers that need finer control can override: open: myCondition || popupHovered
    property bool open: (hoverTarget?.containsMouse ?? false) || popupHovered

    active: true
    property bool popupHovered: false

    component: PanelWindow {
        id: popupWindow
        color:   "transparent"
        visible: root.open

        readonly property real screenWidth:  screen?.width  ?? 0
        readonly property real screenHeight: screen?.height ?? 0

        anchors.left:   !Config.options.bar.vertical || (Config.options.bar.vertical && !Config.options.bar.bottom)
        anchors.right:  Config.options.bar.vertical && Config.options.bar.bottom
        anchors.top:    Config.options.bar.vertical || (!Config.options.bar.vertical && !Config.options.bar.bottom)
        anchors.bottom: !Config.options.bar.vertical && Config.options.bar.bottom

        implicitWidth:  popupBackground.implicitWidth  + Appearance.sizes.elevationMargin * 2 + root.popupBackgroundMargin
        implicitHeight: popupBackground.implicitHeight + Appearance.sizes.elevationMargin * 2 + root.popupBackgroundMargin

        mask: Region { item: popupBackground }

        exclusionMode: ExclusionMode.Ignore
        exclusiveZone: 0

        margins {
            left: {
                if (!Config.options.bar.vertical) {
                    if (!root.hoverTarget || !root.QsWindow) return 0;
                    var targetPos = root.QsWindow.mapFromItem(root.hoverTarget, 0, 0);
                    var centeredX = targetPos.x + (root.hoverTarget.width - popupWindow.implicitWidth) / 2;
                    return Math.max(0, Math.min(screenWidth - popupWindow.implicitWidth, centeredX));
                }
                return Appearance.sizes.verticalBarWidth;
            }
            top: {
                if (!Config.options.bar.vertical) return Appearance.sizes.barHeight;
                if (!root.hoverTarget || !root.QsWindow) return 0;
                var targetPos = root.QsWindow.mapFromItem(root.hoverTarget, 0, 0);
                var centeredY = targetPos.y + (root.hoverTarget.height - popupWindow.implicitHeight) / 2;
                return Math.max(0, Math.min(screenHeight - popupWindow.implicitHeight, centeredY));
            }
            right:  Appearance.sizes.verticalBarWidth
            bottom: Appearance.sizes.barHeight
        }

        WlrLayershell.namespace: "quickshell:popup"
        WlrLayershell.layer:     WlrLayer.Overlay

        StyledRectangularShadow { target: popupBackground }

        // HoverHandler on the background — passive, never blocks child input.
        // Drives root.popupHovered so callers can react via onPopupHoveredChanged.
        HoverHandler {
            target:    popupBackground
            onHoveredChanged: root.popupHovered = hovered
        }

        Rectangle {
            anchors.fill:    popupBackground
            anchors.margins: -1
            radius:          popupBackground.radius + 1
            color:           "transparent"
            border.width:    1
            border.color:    Qt.rgba(
                Appearance.m3colors.m3outlineVariant.r,
                Appearance.m3colors.m3outlineVariant.g,
                Appearance.m3colors.m3outlineVariant.b, 0.55)
            z: popupBackground.z - 1
        }

        Rectangle {
            id: popupBackground
            readonly property real margin: 10

            anchors {
                fill:         parent
                leftMargin:   Appearance.sizes.elevationMargin + root.popupBackgroundMargin * (!popupWindow.anchors.left)
                rightMargin:  Appearance.sizes.elevationMargin + root.popupBackgroundMargin * (!popupWindow.anchors.right)
                topMargin:    Appearance.sizes.elevationMargin + root.popupBackgroundMargin * (!popupWindow.anchors.top)
                bottomMargin: Appearance.sizes.elevationMargin + root.popupBackgroundMargin * (!popupWindow.anchors.bottom)
            }

            implicitWidth:  root.contentItem.implicitWidth  + margin * 2
            implicitHeight: root.contentItem.implicitHeight + margin * 2

            color:  Appearance.m3colors.m3surfaceContainer
            radius: Appearance.rounding.large

            children: [root.contentItem]

            onChildrenChanged: {
                if (root.contentItem) {
                    root.contentItem.anchors.fill    = popupBackground
                    root.contentItem.anchors.margins = margin
                }
            }

            border.width: 1
            border.color: Appearance.m3colors.m3outlineVariant
        }
    }
}
