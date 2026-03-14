import qs.modules.common
import qs.modules.common.widgets
import qs.services
import qs.modules.ii.sidebarDashboard.notifications
import Qt5Compat.GraphicalEffects
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    radius: Appearance.rounding.normal
    // M3: surfaceContainerHigh — matches QuickSliders and BottomWidgetGroup
    color: Appearance.m3colors.m3surfaceContainerHigh
    border.width: 1
    border.color: Qt.rgba(
        Appearance.colors.colPrimary.r,
        Appearance.colors.colPrimary.g,
        Appearance.colors.colPrimary.b, 0.12)

    NotificationList {
        anchors.fill: parent
        anchors.margins: 5
    }
}
