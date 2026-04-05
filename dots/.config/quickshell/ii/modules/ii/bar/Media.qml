import qs.modules.common
import qs.modules.common.widgets
import qs.services
import qs
import qs.modules.common.functions
import QtQuick
import QtQuick.Layouts
import Quickshell.Services.Mpris
import Quickshell.Hyprland
import Qt5Compat.GraphicalEffects
import qs.modules.common.utils

Item {
    id: root
    readonly property MprisPlayer activePlayer: MprisController.activePlayer
    readonly property string cleanedTitle: StringUtils.cleanMusicTitle(activePlayer?.trackTitle) || Translation.tr("No media")

    property int customSize: Config.options.bar.mediaPlayer.customSize
    property int lyricsCustomSize: Config.options.bar.mediaPlayer.lyrics.customSize
    readonly property int maxWidth: 300

    readonly property bool showLoadingIndicator: Config.options.bar.mediaPlayer.lyrics.showLoadingIndicator ?? false
    readonly property bool lyricsEnabled: Config.options.bar.mediaPlayer.lyrics.enable ?? false
    readonly property bool useGradientMask: Config.options.bar.mediaPlayer.lyrics.useGradientMask ?? false
    readonly property string lyricsStyle: Config.options.bar.mediaPlayer.lyrics.style
    readonly property bool artworkEnabled: Config.options.bar.mediaPlayer.artwork.enable

    Layout.fillHeight: true
    implicitWidth: LyricsService.hasSyncedLines && root.lyricsEnabled ? lyricsCustomSize : customSize
    implicitHeight: Appearance.sizes.barHeight

    Behavior on implicitWidth {
        animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(root)
    }

    Component.onCompleted: {
        LyricsService.initiliazeLyrics()
    }

    readonly property string artSource: activePlayer?.trackArtUrl && activePlayer.trackArtUrl !== "" ? activePlayer.trackArtUrl : ""

    Item {
        id: artworkItem
        visible: artworkEnabled
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: artworkEnabled ? artworkBoxSize : 0
        height: artworkEnabled ? artworkBoxSize : 0

        Rectangle {
            anchors.fill: parent
            color: Appearance.colors.colPrimaryContainer
            radius: Appearance.rounding.full

            Image {
                anchors.fill: parent
                source: root.artSource
                fillMode: Image.PreserveAspectCrop
                cache: false
                antialiasing: true
                width: parent.width
                height: parent.height
                sourceSize.width: width
                sourceSize.height: height

                layer.enabled: true
                layer.effect: OpacityMask {
                    maskSource: Rectangle {
                        width: artworkItem.width
                        height: artworkItem.height
                        radius: Appearance.rounding.full
                    }
                }
            }

            MaterialSymbol {
                anchors.centerIn: parent
                visible: root.artSource.length === 0
                fill: 1
                text: "music_note"
                iconSize: Math.max(12, artworkItem.width * 0.5)
                color: Appearance.colors.colOnSecondaryContainer
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.MiddleButton | Qt.BackButton | Qt.ForwardButton | Qt.RightButton | Qt.LeftButton
        cursorShape: Qt.PointingHandCursor
        onPressed: (event) => {
            if (!activePlayer && event.button !== Qt.LeftButton) return;
            if (event.button === Qt.MiddleButton) {
                activePlayer.togglePlaying();
            } else if (event.button === Qt.BackButton) {
                activePlayer.previous();
            } else if (event.button === Qt.ForwardButton || event.button === Qt.RightButton) {
                activePlayer.next();
            } else if (event.button === Qt.LeftButton) {
                var globalPos = root.mapToItem(null, 0, 0);
                Persistent.states.media.popupRect = Qt.rect(globalPos.x, globalPos.y, root.width, root.height);
                GlobalStates.mediaControlsOpen = !GlobalStates.mediaControlsOpen;
            }
        }
    }

    ClippedFilledCircularProgress {
        id: mediaCircProg
        visible: true

        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        x: artworkEnabled ? root.width - width : 0

        lineWidth: Appearance.rounding.unsharpen
        value: activePlayer?.position / activePlayer?.length
        implicitSize: 20
        colPrimary: Appearance.m3colors.m3onSecondaryContainer
        enableAnimation: true

        Item {
            anchors.centerIn: parent
            width: mediaCircProg.implicitSize
            height: mediaCircProg.implicitSize

            MaterialSymbol {
                anchors.centerIn: parent
                width: mediaCircProg.implicitSize
                height: mediaCircProg.implicitSize
                
                MaterialSymbol {
                    anchors.centerIn: parent
                    fill: 1
                    text: activePlayer?.isPlaying ? "pause" : "music_note"
                    iconSize: Appearance.font.pixelSize.normal
                    color: Appearance.m3colors.m3onSecondaryContainer
                }
            }
        }
    }

    StyledText {
        visible: !LyricsService.hasSyncedLines || !lyricsEnabled
        width: parent.width - mediaCircProg.implicitSize * 2

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.horizontalCenterOffset: mediaCircProg.implicitSize / 2
        anchors.verticalCenter: parent.verticalCenter

        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight // Truncates the text on the right
        color: Appearance.m3colors.m3onSurface
        text: `${cleanedTitle}${activePlayer?.trackArtist ? ' • ' + activePlayer.trackArtist : ''}`
    }

    Loader {
        id: lyricsItemLoader
        active: lyricsEnabled

        width: artworkEnabled ? parent.width - (artworkItem.width + mediaCircProg.implicitSize * 2) : parent.width - mediaCircProg.implicitSize * 2
        height: parent.height

        anchors.left: parent.left
        anchors.leftMargin: artworkEnabled ? mediaCircProg.implicitSize * 1.5 + artworkContentPadding : mediaCircProg.implicitSize * 1.5

        sourceComponent: Item {
            id: lyricsItem
            visible: lyricsEnabled

            anchors.centerIn: parent

            Loader {
                active: lyricsStyle == "static"
                anchors.fill: parent
                anchors.centerIn: parent
                sourceComponent: LyricsStatic {
                    anchors.fill: parent
                    anchors.centerIn: parent
                    horizontalAlignment: Text.AlignHCenter
                }
            }

            Loader {
                active: lyricsStyle == "scroller"
                anchors.fill: parent
                sourceComponent: LyricScroller {
                    id: lyricScroller

                    anchors.fill: parent
                    visible: lyricsStyle == "scroller" && LyricsService.hasSyncedLines

                    defaultLyricsSize: Appearance.font.pixelSize.smallest
                        useGradientMask: root.useGradientMask
                        halfVisibleLines: 1
                        downScale: 0.98
                        rowHeight: 10
                        gradientDensity: 0.25
                }
            }
        }
    }

}
