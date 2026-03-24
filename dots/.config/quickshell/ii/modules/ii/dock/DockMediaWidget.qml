import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.utils
import qs.modules.common.functions

Item {
    id: root

    property bool isVertical: false

    readonly property real buttonSize: Appearance.sizes.dockButtonSize
    readonly property real dotMargin: (Config.options?.dock.height ?? 60) * 0.2
    readonly property real slotSize: buttonSize + dotMargin * 2
    readonly property real fixedSlots: isVertical ? 2.5 : 3
    readonly property real fixedLength: fixedSlots * slotSize

    readonly property real artSize: Math.round(buttonSize * 0.9)
    readonly property real artInner: artSize

    readonly property real controlSize: Math.round(buttonSize * 0.68)

    readonly property int textSizeL: Math.round(buttonSize * (isVertical ? 0.24 : 0.26))
    readonly property int textSizeS: Math.round(buttonSize * (isVertical ? 0.20 : 0.22))
    readonly property int marqueeRunningThreshold: isVertical ? 10 : 14

    implicitWidth: isVertical ? slotSize : fixedLength
    implicitHeight: isVertical ? fixedLength : slotSize

    readonly property MprisPlayer currentPlayer: MprisController.activePlayer
    readonly property bool isPlaying: currentPlayer?.isPlaying ?? false

    readonly property string finalTitle: StringUtils.cleanMusicTitle(currentPlayer?.trackTitle) || Translation.tr("Unknown Title")
    readonly property string finalArtist: currentPlayer?.trackArtist || Translation.tr("Unknown Artist")
    readonly property string finalArtUrl: currentPlayer?.trackArtUrl || ""

    property bool mediaHovered: false

    HoverHandler {
        onHoveredChanged: root.mediaHovered = hovered
    }

    component ArtworkItem: Item {
        width: root.artSize
        height: root.artSize

        Rectangle {
            id: artRect
            anchors.centerIn: parent
            width: root.artInner
            height: root.artInner
            radius: Appearance.rounding.small
            color: Appearance.colors.colPrimaryContainer

            layer.enabled: true
            layer.effect: OpacityMask {
                maskSource: Rectangle {
                    width: artRect.width
                    height: artRect.height
                    radius: Appearance.rounding.small
                }
            }

            Image {
                id: artImg
                anchors.fill: parent
                source: root.finalArtUrl
                fillMode: Image.PreserveAspectCrop
                cache: true
                antialiasing: true
                asynchronous: true
                visible: status === Image.Ready
            }
        }

        MaterialSymbol {
            anchors.centerIn: artRect
            visible: artImg.status !== Image.Ready
            text: "music_note"
            iconSize: root.artInner * 0.48
            color: Appearance.colors.colPrimary
        }
    }


    component NextButton: RippleButton {
        id: nextBtn
        width: root.controlSize
        height: root.controlSize
        buttonRadius: Appearance.rounding.full
        onClicked: root.currentPlayer?.next()
        rippleEnabled: false
        colBackground: "transparent"
        colBackgroundHover: "transparent"
        colBackgroundToggled: "transparent"
        colBackgroundToggledHover: "transparent"

        MaterialSymbol {
            anchors.centerIn: parent
            iconSize: root.controlSize * 0.72
            fill: 1
            text: "skip_next"
            color: Appearance.colors.colOnLayer0
        }
    }
    
    component PlayButton: RippleButton {
        id: playBtn
        width: root.controlSize
        height: root.controlSize
        buttonRadius: Appearance.rounding.full
        onClicked: root.currentPlayer?.togglePlaying()
        rippleEnabled: false
        colBackground: "transparent"
        colBackgroundHover: "transparent"
        colBackgroundToggled: "transparent"
        colBackgroundToggledHover: "transparent"

        MaterialSymbol {
            anchors.centerIn: parent
            iconSize: root.controlSize * 0.72
            fill: 1
            text: root.isPlaying ? "pause" : "play_arrow"
            color: Appearance.colors.colOnLayer0
        }
    }

    Loader {
        active: !root.isVertical
        anchors.fill: parent
        sourceComponent: Item {
            anchors.fill: parent

            ArtworkItem {
                id: artH
                anchors.left: parent.left
                anchors.leftMargin: root.dotMargin + musicSepWrapper.Layout.preferredWidth
                anchors.verticalCenter: parent.verticalCenter
            }

            Row {
                id: controlsH
                anchors.right: parent.right
                anchors.rightMargin: root.dotMargin * 0.4
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                PlayButton {}
                NextButton {}
            }

            ColumnLayout {
                anchors.left: artH.right
                anchors.right: controlsH.left
                anchors.leftMargin: root.dotMargin * 0.6
                anchors.rightMargin: root.dotMargin * 0.3
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                Item {
                    Layout.fillWidth: true
                    implicitHeight: titleH.implicitHeight
                    clip: true
                    MarqueeText {
                        id: titleH
                        width: parent.width
                        text: root.finalTitle
                        fontSize: root.textSizeL
                        fontWeight: Font.DemiBold
                        textColor: Appearance.colors.colOnLayer0
                        running: root.mediaHovered && text.length > root.marqueeRunningThreshold
                    }
                }

                Item {
                    Layout.fillWidth: true
                    implicitHeight: artistH.implicitHeight
                    clip: true
                    StyledText {
                        id: artistH
                        width: parent.width
                        text: root.finalArtist
                        font.pixelSize: root.textSizeS
                        font.weight: Font.Normal
                        color: Appearance.colors.colSubtext
                    }
                }
            }
        }
    }
    
    Loader {
        active: root.isVertical
        anchors.fill: parent
        sourceComponent: Item {
            anchors.fill: parent

            ArtworkItem {
                id: artV
                anchors.top: parent.top
                anchors.topMargin: root.dotMargin + musicSepWrapper.Layout.preferredHeight
                anchors.horizontalCenter: parent.horizontalCenter
            }

            Column {
                id: controlsV
                anchors.bottom: parent.bottom
                anchors.bottomMargin: root.dotMargin * 0.6
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 0

                PlayButton {}
                NextButton {}
            }

            ColumnLayout {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: artV.bottom
                anchors.topMargin: root.dotMargin 
                anchors.leftMargin: root.dotMargin
                anchors.rightMargin: root.dotMargin
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: Math.round((artV.height - controlsV.height) / 2)
                spacing: 2

                MarqueeText {
                    id: titleV
                    Layout.fillWidth: true
                    text: root.finalTitle
                    fontSize: root.textSizeL
                    fontWeight: Font.DemiBold
                    textColor: Appearance.colors.colOnLayer0
                    running: root.mediaHovered && text.length > root.marqueeRunningThreshold
                }

                StyledText {
                    id: artistV
                    Layout.fillWidth: true
                    text: root.finalArtist
                    font.pixelSize: root.textSizeS
                    font.weight: Font.Normal
                    color: Appearance.colors.colSubtext
                }
            }
        }
    }
    
}
