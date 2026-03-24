pragma ComponentBehavior: Bound
import qs
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Hyprland

Scope {
    id: root

    function dismiss() {
        GlobalStates.regionSelectorOpen = false;
    }

    Loader {
        id: regionSelectorLoader
        active: GlobalStates.regionSelectorOpen

        sourceComponent: WRegionSelectionPanel {
            onClosed: root.dismiss()
        }
    }

    function screenshot() {
        GlobalStates.regionSelectorOpen = true;
    }

    function configureAndOpen(mediaType, actionKey, actionValue) {
        GlobalStates.regionSelectorOpen = true;
        Qt.callLater(() => {
            if (!regionSelectorLoader.item) return;
            regionSelectorLoader.item.mediaType = mediaType;
            if (actionKey === "imageAction")
                regionSelectorLoader.item.imageAction = actionValue;
            else if (actionKey === "videoAction")
                regionSelectorLoader.item.videoAction = actionValue;
        });
    }

    function ocr() {
        configureAndOpen(WRegionSelectionPanel.MediaType.Image, "imageAction", WRegionSelectionPanel.ImageAction.CharRecognition);
    }

    function record() {
        configureAndOpen(WRegionSelectionPanel.MediaType.Video, "videoAction", WRegionSelectionPanel.VideoAction.Record);
    }

    function recordWithSound() {
        configureAndOpen(WRegionSelectionPanel.MediaType.Video, "videoAction", WRegionSelectionPanel.VideoAction.RecordWithSound);
    }

    function search() {
        configureAndOpen(WRegionSelectionPanel.MediaType.Image, "imageAction", WRegionSelectionPanel.ImageAction.Search);
    }

    IpcHandler {
        target: "region"

        function screenshot() {
            root.screenshot();
        }
        function ocr() {
            root.ocr();
        }
        function record() {
            root.record();
        }
        function recordWithSound() {
            root.recordWithSound();
        }
        function search() {
            root.search();
        }
    }

    GlobalShortcut {
        name: "regionScreenshot"
        description: "Takes a screenshot of the selected region"
        onPressed: root.screenshot()
    }
    GlobalShortcut {
        name: "regionSearch"
        description: "Searches the selected region"
        onPressed: root.search()
    }
    GlobalShortcut {
        name: "regionOcr"
        description: "Recognizes text in the selected region"
        onPressed: root.ocr()
    }
    GlobalShortcut {
        name: "regionRecord"
        description: "Records the selected region"
        onPressed: root.record()
    }
    GlobalShortcut {
        name: "regionRecordWithSound"
        description: "Records the selected region with sound"
        onPressed: root.recordWithSound()
    }
}
