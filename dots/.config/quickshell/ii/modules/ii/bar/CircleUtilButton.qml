import qs.modules.common
import qs.modules.common.widgets
import QtQuick

RippleButton {
    id: button

    required default property Item content
    property bool extraActiveCondition: false

    implicitHeight: Math.max(content.implicitHeight, 26, content.implicitHeight)
    implicitWidth: implicitHeight
    contentItem: content

    buttonRadius: Appearance.rounding.full
    colBackground: "transparent"
    colBackgroundHover: Appearance.m3colors.m3surfaceContainerHighest
    colRipple: Qt.rgba(Appearance.colors.colPrimary.r, Appearance.colors.colPrimary.g, Appearance.colors.colPrimary.b, 0.12)
    colBackgroundToggled: Appearance.m3colors.m3secondaryContainer
    colBackgroundToggledHover: Qt.rgba(Appearance.m3colors.m3secondaryContainer.r, Appearance.m3colors.m3secondaryContainer.g, Appearance.m3colors.m3secondaryContainer.b, 0.85)
    colRippleToggled: Qt.rgba(Appearance.m3colors.m3onSecondaryContainer.r, Appearance.m3colors.m3onSecondaryContainer.g, Appearance.m3colors.m3onSecondaryContainer.b, 0.12)

}
