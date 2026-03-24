import QtQuick
import QtQuick.Layouts
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets

RippleButton { // Right sidebar button
    id: rightSidebarButton

    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
    Layout.rightMargin: Appearance.rounding.screenRounding
    Layout.fillWidth: false

    implicitWidth: indicatorsRowLayout.implicitWidth + 10 * 2
    implicitHeight: indicatorsRowLayout.implicitHeight + 5 * 2

    buttonRadius: Appearance.rounding.full
    colBackground: Appearance.m3colors.m3surfaceContainerHigh
    colBackgroundHover: Appearance.m3colors.m3surfaceContainerHighest
    colRipple: Qt.rgba(Appearance.colors.colPrimary.r, Appearance.colors.colPrimary.g, Appearance.colors.colPrimary.b, 0.12)
    colBackgroundToggled: Appearance.m3colors.m3secondaryContainer
    colBackgroundToggledHover: Qt.rgba(Appearance.m3colors.m3secondaryContainer.r, Appearance.m3colors.m3secondaryContainer.g, Appearance.m3colors.m3secondaryContainer.b, 0.85)
    colRippleToggled: Qt.rgba(Appearance.m3colors.m3onSecondaryContainer.r, Appearance.m3colors.m3onSecondaryContainer.g, Appearance.m3colors.m3onSecondaryContainer.b, 0.12)
    toggled: GlobalStates.sidebarRightOpen
    property color colText: toggled ? Appearance.m3colors.m3onSecondaryContainer : Appearance.m3colors.m3onSurface

    Behavior on colText {
        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
    }

    onPressed: {
        GlobalStates.sidebarRightOpen = !GlobalStates.sidebarRightOpen;
    }

    RowLayout {
        id: indicatorsRowLayout
        anchors.centerIn: parent
        property real realSpacing: 15
        spacing: 0

        Revealer {
            reveal: Audio.sink?.audio?.muted ?? false
            Layout.fillHeight: true
            Layout.rightMargin: reveal ? indicatorsRowLayout.realSpacing : 0
            Behavior on Layout.rightMargin {
                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
            }
            MaterialSymbol {
                text: "volume_off"
                iconSize: Appearance.font.pixelSize.larger
                color: rightSidebarButton.colText
            }
        }
        Revealer {
            reveal: Audio.source?.audio?.muted ?? false
            Layout.fillHeight: true
            Layout.rightMargin: reveal ? indicatorsRowLayout.realSpacing : 0
            Behavior on Layout.rightMargin {
                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
            }
            MaterialSymbol {
                text: "mic_off"
                iconSize: Appearance.font.pixelSize.larger
                color: rightSidebarButton.colText
            }
        }
        HyprlandXkbIndicator {
            Layout.alignment: Qt.AlignVCenter
            Layout.rightMargin: indicatorsRowLayout.realSpacing
            color: rightSidebarButton.colText
        }
        Revealer {
            reveal: Notifications.silent || Notifications.unread > 0
            Layout.fillHeight: true
            Layout.rightMargin: reveal ? indicatorsRowLayout.realSpacing : 0
            implicitHeight: reveal ? notificationUnreadCount.implicitHeight : 0
            implicitWidth: reveal ? notificationUnreadCount.implicitWidth : 0
            Behavior on Layout.rightMargin {
                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
            }
            NotificationUnreadCount {
                id: notificationUnreadCount
            }
        }
        MaterialSymbol {
            text: Network.materialSymbol
            iconSize: Appearance.font.pixelSize.larger
            color: rightSidebarButton.colText
        }
        MaterialSymbol {
            Layout.leftMargin: indicatorsRowLayout.realSpacing
            visible: BluetoothStatus.available
            text: BluetoothStatus.connected ? "bluetooth_connected" : BluetoothStatus.enabled ? "bluetooth" : "bluetooth_disabled"
            iconSize: Appearance.font.pixelSize.larger
            color: rightSidebarButton.colText
        }
    }
}
