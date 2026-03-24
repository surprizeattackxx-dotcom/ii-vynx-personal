import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.widgets

Column {
    id: root
    required property var icon
    required property var label
    property int    count:      0
    property string timestamp:  ""
    // M3: primaryContainer is the correct tonal role for accent bands
    property color  countColor: Appearance.m3colors.m3primary
    spacing: 0

    // M3 secondaryContainer tonal band with left primary strip
    Rectangle {
        width:         headerRow.implicitWidth + 26
        implicitWidth: headerRow.implicitWidth + 26
        height:        headerRow.implicitHeight + 14
        radius:        Appearance.rounding.small

        // M3: secondaryContainer for tonal background behind headers
        color:        Appearance.m3colors.m3secondaryContainer
        border.width: 1
        // M3: outlineVariant for the band border
        border.color: Appearance.m3colors.m3outlineVariant

        // M3: primary-colored left accent strip
        Rectangle {
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom; margins: 4 }
            width: 3; radius: 2
            color: root.countColor
        }

        Row {
            id: headerRow
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: 14
            spacing: 6

            MaterialSymbol {
                anchors.verticalCenter: parent.verticalCenter
                fill: 0
                font.weight: Font.DemiBold
                text: root.icon
                iconSize: Appearance.font.pixelSize.large
                // M3: onSecondaryContainer for icons inside secondaryContainer
                color: Appearance.m3colors.m3onSecondaryContainer
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: root.label
                font { weight: Font.Bold; pixelSize: Appearance.font.pixelSize.normal }
                // M3: onSecondaryContainer for text inside secondaryContainer
                color: Appearance.m3colors.m3onSecondaryContainer
            }

            // M3 count badge — primaryContainer fill with primary border
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.count > 0
                implicitWidth:  badgeLabel.implicitWidth + 16
                implicitHeight: badgeLabel.implicitHeight + 5
                radius: height / 2
                // M3: primaryContainer for badge background
                color:        Appearance.m3colors.m3primaryContainer
                border.width: 1
                border.color: root.countColor
                StyledText {
                    id: badgeLabel
                    anchors.centerIn: parent
                    text: root.count
                    font { weight: Font.ExtraBold; pixelSize: Appearance.font.pixelSize.small }
                    // M3: onPrimaryContainer for text on primaryContainer
                    color: Appearance.m3colors.m3onPrimaryContainer
                }
            }
        }
    }

    // Timestamp row
    Row {
        visible: root.timestamp !== ""
        spacing: 4
        leftPadding: 6
        topPadding: 4

        // M3: outline for subtle de-emphasised iconography
        MaterialSymbol { text: "schedule"; iconSize: 11; color: Appearance.m3colors.m3outline }
        StyledText {
            text: qsTr("Last checked: ") + root.timestamp
            font.pixelSize: 10
            // M3: onSurfaceVariant for secondary / de-emphasised text
            color: Appearance.m3colors.m3onSurfaceVariant
        }
    }
}
