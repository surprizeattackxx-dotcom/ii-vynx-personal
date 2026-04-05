import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs
import QtQuick

import "./widgets"

DockButton {
    id: root

    property var appToplevel: null
    property var dockContent: null
    property int delegateIndex: -1
    property int lastFocused: -1

    readonly property bool isSeparator: appToplevel.appId === "SEPARATOR"
    property var desktopEntry: DesktopEntries.heuristicLookup(appToplevel.appId)

    Timer {
        // Retry looking up the desktop entry if it failed (e.g. database not loaded yet)
        property int retryCount: 5
        interval: 1000
        running: !root.isSeparator && root.desktopEntry === null && retryCount > 0
        repeat: true
        onTriggered: {
            retryCount--;
            root.desktopEntry = DesktopEntries.heuristicLookup(root.appToplevel.appId);
        }
    }

    enabled: !isSeparator
    implicitWidth: isSeparator ? 1 : implicitHeight - topInset - bottomInset

    Loader {
        active: isSeparator
        anchors {
            fill: parent
            topMargin: dockVisualBackground.margin + dockRow.padding + Appearance.rounding.normal
            bottomMargin: dockVisualBackground.margin + dockRow.padding + Appearance.rounding.normal
        }
        sourceComponent: DockSeparator {}
    }

        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        preventStealing: drag.active

        drag.target: appToplevel ? dockContent.dragGhostItem : null
        drag.axis: root.isVertical ? Drag.YAxis : Drag.XAxis
        drag.threshold: 4

        readonly property real ghostHalf: (dockContent?.dragGhostItem?.width ?? 0) / 2

        drag.minimumX: root.isVertical ? 0 : (dockContent?.pinButtonCenter ?? 0) - ghostHalf
        drag.maximumX: root.isVertical ? 0 : (dockContent?.unpinButtonCenter ?? 0) - ghostHalf
        drag.minimumY: root.isVertical ? (dockContent?.pinButtonCenter ?? 0) - ghostHalf : 0
        drag.maximumY: root.isVertical ? (dockContent?.unpinButtonCenter ?? 0) - ghostHalf : 0

        property bool wasDragging: false

        onEntered: {
            if (dockContent?.suppressHover) return
            if (appToplevel?.toplevels?.length > 0) {
                dockContent.lastHoveredButton = root
                dockContent.buttonHovered = true
            } else {
                dockContent.buttonHovered = false
                dockContent.popupIsResizing = false
            }
            if (appToplevel && appToplevel.toplevels)
                lastFocused = appToplevel.toplevels.length - 1
        }

        onExited: {
            if (dockContent?.lastHoveredButton === root)
                dockContent.buttonHovered = false
        }

        onPressed: (mouse) => {
            wasDragging = false
            if (dockContent?.dragGhostItem && appToplevel) {
                const p = root.mapToItem(dockContent, 0, 0)
                dockContent.dragGhostItem.x = p.x + root.dotMargin
                dockContent.dragGhostItem.y = p.y + root.dotMargin
            }
        }

        onPositionChanged: (mouse) => {
            if (!drag.active || !appToplevel) return
            if (!wasDragging) {
                wasDragging = true
                dockContent.startDrag(root.appToplevel.appId, root.delegateIndex)
            }
            dockContent.moveDrag()
        }

        onReleased: (mouse) => {
            if (wasDragging) {
                wasDragging = false
                dockContent.endDrag()
                return
            }
            if (mouse.button === Qt.RightButton) {
                dockContent.buttonHovered = false
                dockContent.lastHoveredButton = null
                dockContextMenu.open()
                return
            }
            if (mouse.button === Qt.MiddleButton) {
                root.desktopEntry?.execute()
                return
            }
            if (!appToplevel || appToplevel.toplevels.length === 0) {
                root.desktopEntry?.execute()
                return
            }
            // Cycle through open windows on left click
            lastFocused = (lastFocused + 1) % appToplevel.toplevels.length
            appToplevel.toplevels[lastFocused].activate()
        }
    }

    altAction: () => {
        dockContent.buttonHovered = false
        dockContent.lastHoveredButton = null
        dockContextMenu.open()
    }

    DockContextMenu {
        id: dockContextMenu
        appToplevel: root.appToplevel
        desktopEntry: root.desktopEntry
        anchorItem: root
    }

    Connections {
        target: dockContextMenu
        function onActiveChanged() {
            if (dockContent)
                dockContent.anyContextMenuOpen = dockContextMenu.active
        }
    }

    DockAppIcon {}
    DockAppIndicator {}
}
