import QtQuick
import Quickshell
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

QuickToggleModel {
    name: Translation.tr("Dark Mode")
    statusText: Appearance.m3colors.darkmode ? Translation.tr("Dark") : Translation.tr("Light")

    toggled: Appearance.m3colors.darkmode
    icon: "contrast"
    
    mainAction: () => {
        Quickshell.execDetached([Directories.darkModeToggleScriptPath]);
        MaterialThemeLoader.reloadAfterExternalColorChange();
    }

    rightClickOnlyAlt: true
    altAction: () => {
        if (Persistent.ready)
            Persistent.states.followNightLight = !Persistent.states.followNightLight;
    }

    tooltipText: Translation.tr("Dark Mode — Right-click: Follow Night Light")
}
