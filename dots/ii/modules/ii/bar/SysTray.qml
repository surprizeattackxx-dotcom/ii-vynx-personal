import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Services.SystemTray
import qs.services
import qs.modules.common
import qs.modules.common.widgets

Item {
    id: root
    property real visualWidth: gridLayout.implicitWidth
    property real visualHeight: gridLayout.implicitHeight
    implicitWidth: visualWidth
    implicitHeight: visualHeight
    property bool vertical: false
    property bool invertSide: Config?.options.bar.bottom
    property bool trayOverflowOpen: false
    property bool showSeparator: true
    property bool showOverflowMenu: !Config.options.tray.invertPinnedItems
    property var activeMenu: null

    property list<var> pinnedItems: TrayService.pinnedItems
    property list<var> unpinnedItems: TrayService.unpinnedItems

    onUnpinnedItemsChanged: {
        if (unpinnedItems.length == 0) root.closeOverflowMenu();
        // Use total item count across both lists so the tray isn't hidden
        // just because one half is temporarily empty.
        rootItem.toggleVisible(pinnedItems.length > 0 || unpinnedItems.length > 0);
    }
    onPinnedItemsChanged: {
        rootItem.toggleVisible(pinnedItems.length > 0 || unpinnedItems.length > 0);
    }

    function grabFocus() {
        focusGrab.active = true;
    }

    function setExtraWindowAndGrabFocus(window) {
        root.activeMenu = window;
        root.grabFocus();
    }

    function releaseFocus() {
        focusGrab.active = false;
    }

    function closeOverflowMenu() {
        focusGrab.active = false;
    }

    onTrayOverflowOpenChanged: {
        if (root.trayOverflowOpen) {
            root.grabFocus();
        }
    }

    HyprlandFocusGrab {
        id: focusGrab
        active: false
        // Filter out null windows so onCleared doesn't fire spuriously
        // when the overflow popup window reference is not yet created.
        windows: {
            var wins = [];
            var overflowWin = trayOverflowLayout.QsWindow?.window ?? null;
            if (overflowWin !== null) wins.push(overflowWin);
            if (root.activeMenu !== null) wins.push(root.activeMenu);
            return wins;
        }
        onCleared: {
            root.trayOverflowOpen = false;
            if (root.activeMenu) {
                root.activeMenu.close();
                root.activeMenu = null;
            }
        }
    }

    GridLayout {
        id: gridLayout
        columns: root.vertical ? 1 : -1
        anchors.centerIn: parent
        rowSpacing: 8
        columnSpacing: 15

        RippleButton {
            id: trayOverflowButton
            visible: root.showOverflowMenu && root.unpinnedItems.length > 0
            toggled: root.trayOverflowOpen
            property bool containsMouse: hovered

            downAction: () => root.trayOverflowOpen = !root.trayOverflowOpen

            Layout.fillHeight: !root.vertical
            Layout.fillWidth: root.vertical
            background.implicitWidth: 24
            background.implicitHeight: 24
            background.anchors.centerIn: this
            colBackgroundToggled: Appearance.m3colors.m3secondaryContainer
            colBackgroundToggledHover: Qt.rgba(Appearance.m3colors.m3secondaryContainer.r, Appearance.m3colors.m3secondaryContainer.g, Appearance.m3colors.m3secondaryContainer.b, 0.85)
            colRippleToggled: Qt.rgba(Appearance.m3colors.m3onSecondaryContainer.r, Appearance.m3colors.m3onSecondaryContainer.g, Appearance.m3colors.m3onSecondaryContainer.b, 0.12)

            contentItem: MaterialSymbol {
                anchors.centerIn: parent
                iconSize: Appearance.font.pixelSize.larger
                text: "expand_more"
                horizontalAlignment: Text.AlignHCenter
                color: root.trayOverflowOpen ? Appearance.m3colors.m3onSecondaryContainer : Appearance.m3colors.m3onSurface
                rotation: (root.trayOverflowOpen ? 180 : 0) - (90 * root.vertical) + (180 * root.invertSide)
                Behavior on rotation {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                }
            }

            StyledPopup {
                id: overflowPopup
                hoverTarget: trayOverflowButton
                active: root.trayOverflowOpen && root.unpinnedItems.length > 0

                GridLayout {
                    id: trayOverflowLayout
                    anchors.centerIn: parent
                    columns: Math.ceil(Math.sqrt(root.unpinnedItems.length))
                    columnSpacing: 10
                    rowSpacing: 10

                    Repeater {
                        model: root.unpinnedItems

                        delegate: SysTrayItem {
                            required property SystemTrayItem modelData
                            item: modelData
                            Layout.fillHeight: !root.vertical
                            Layout.fillWidth: root.vertical
                            onMenuClosed: root.releaseFocus();
                            onMenuOpened: (qsWindow) => root.setExtraWindowAndGrabFocus(qsWindow);
                        }
                    }
                }
            }
        }

        Repeater {
            model: ScriptModel {
                values: root.pinnedItems
            }

            delegate: SysTrayItem {
                required property SystemTrayItem modelData
                item: modelData
                Layout.fillHeight: !root.vertical
                Layout.fillWidth: root.vertical
                onMenuClosed: root.releaseFocus();
                onMenuOpened: (qsWindow) => {
                    root.setExtraWindowAndGrabFocus(qsWindow);
                }
            }
        }

        /* StyledText { //? its a bit useless for me
         *            Layout.alignment: Qt.AlignVCenter | Qt.AlignHCenter
         *            font.pixelSize: Appearance.font.pixelSize.larger
         *            color: Appearance.colors.colSubtext
         *            text: "•"
         *            visible: root.showSeparator && SystemTray.items.values.length > 0
    } */
    }
}
