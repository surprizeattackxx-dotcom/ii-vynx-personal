import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.widgets

RowLayout {
    id: root
    required property string icon
    required property string label
    required property string value
    property string subtitle:   ""
    // M3: primary is the correct tonal role for leading icon containers
    property color  iconColor:  Appearance.m3colors.m3primary
    // M3: onSurface for the primary value text
    property color  valueColor: Appearance.m3colors.m3onSurface
    spacing: 10

    // M3 leading icon container — primaryContainer tonal surface
    Rectangle {
        implicitWidth:  32
        implicitHeight: 32
        radius:         8
        // M3: primaryContainer as the icon container fill
        color:        Appearance.m3colors.m3primaryContainer
        border.width: 1
        // M3: outlineVariant for a soft container border
        border.color: Appearance.m3colors.m3outlineVariant

        MaterialSymbol {
            anchors.centerIn: parent
            text:     root.icon
            iconSize: 16
            // M3: onPrimaryContainer for icons inside primaryContainer
            color:    Appearance.m3colors.m3onPrimaryContainer
        }
    }

    // Label + optional subtitle
    Column {
        Layout.fillWidth: true
        spacing: 1

        StyledText {
            text:  root.label
            // M3: onSurfaceVariant for secondary label text
            color: Appearance.m3colors.m3onSurfaceVariant
            font { weight: Font.Medium; pixelSize: Appearance.font.pixelSize.small }
        }
        StyledText {
            visible:        root.subtitle !== ""
            text:           root.subtitle
            font.pixelSize: 10
            // M3: onSurfaceVariant at reduced opacity for tertiary/hint text
            color: Qt.rgba(
                Appearance.m3colors.m3onSurfaceVariant.r,
                Appearance.m3colors.m3onSurfaceVariant.g,
                Appearance.m3colors.m3onSurfaceVariant.b, 0.65)
        }
    }

    // Right-aligned value — onSurface for prominent readable text
    StyledText {
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignRight
        visible: root.value !== ""
        color:   root.valueColor
        text:    root.value
    }
}
