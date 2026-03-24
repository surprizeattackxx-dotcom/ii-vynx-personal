import qs.modules.common
import qs.modules.common.widgets
import QtQuick

RippleButton {
    id: button
    property string buttonText: ""
    property string tooltipText: ""
    property bool forceCircle: false

    implicitHeight: 30
    implicitWidth: forceCircle ? implicitHeight : (contentItem.implicitWidth + 10 * 2)
    Behavior on implicitWidth {
        SmoothedAnimation { velocity: Appearance.animation.elementMove.velocity }
    }

    background.anchors.fill: button
    buttonRadius: Appearance.rounding.full
    // M3: surfaceContainerHighest for nav/header buttons (highest elevation tier)
    colBackground:      Appearance.m3colors.m3surfaceContainerHighest
    colBackgroundHover: Qt.lighter(Appearance.m3colors.m3surfaceContainerHighest, 1.08)
    colRipple:          Qt.rgba(
        Appearance.colors.colPrimary.r,
        Appearance.colors.colPrimary.g,
        Appearance.colors.colPrimary.b, 0.18)

    contentItem: StyledText {
        text: buttonText
        horizontalAlignment: Text.AlignHCenter
        font.pixelSize: Appearance.font.pixelSize.larger
        color: Appearance.m3colors.m3onSurface
    }

    StyledToolTip {
        text: tooltipText
        extraVisibleCondition: tooltipText.length > 0
    }
}
