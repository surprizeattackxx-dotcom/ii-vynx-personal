pragma Singleton

import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Services.SystemTray

Singleton {
    id: root

    property bool smartTray: Config.options.tray.filterPassive
    property var allItems: []
    property var pinnedList: Config.options.tray.pinnedItems
    property bool invertPins: Config.options.tray.invertPinnedItems

    function _refreshItems() {
        allItems = SystemTray.items.values.slice();
    }

    Component.onCompleted: Qt.callLater(_refreshItems)

    Connections {
        target: SystemTray.items
        function onObjectInsertedPost() { root._refreshItems() }
        function onObjectRemovedPost()  { root._refreshItems() }
    }

    onSmartTrayChanged:  _refreshItems()
    onPinnedListChanged: _refreshItems()
    onInvertPinsChanged: _refreshItems()

    property list<var> itemsInUserList: {
        var items = root.allItems;
        var pinned = root.pinnedList;
        var smart = root.smartTray;
        return items.filter(i => (pinned.includes(i.id) && (!smart || i.status !== Status.Passive)));
    }
    property list<var> itemsNotInUserList: {
        var items = root.allItems;
        var pinned = root.pinnedList;
        var smart = root.smartTray;
        return items.filter(i => (!pinned.includes(i.id) && (!smart || i.status !== Status.Passive)));
    }

    property list<var> pinnedItems: invertPins ? itemsNotInUserList : itemsInUserList
    property list<var> unpinnedItems: invertPins ? itemsInUserList : itemsNotInUserList

    function getTooltipForItem(item) {
        var result = item.tooltipTitle.length > 0 ? item.tooltipTitle
        : (item.title.length > 0 ? item.title : item.id);
        if (item.tooltipDescription.length > 0) result += " • " + item.tooltipDescription;
        if (Config.options.tray.showItemId) result += "\n[" + item.id + "]";
        return result;
    }

    function pin(itemId) {
        var pins = Config.options.tray.pinnedItems;
        if (pins.includes(itemId)) return;
        Config.options.tray.pinnedItems.push(itemId);
    }
    function unpin(itemId) {
        Config.options.tray.pinnedItems = Config.options.tray.pinnedItems.filter(id => id !== itemId);
    }
    function togglePin(itemId) {
        var pins = Config.options.tray.pinnedItems;
        if (pins.includes(itemId)) {
            unpin(itemId)
        } else {
            pin(itemId)
        }
    }
}
