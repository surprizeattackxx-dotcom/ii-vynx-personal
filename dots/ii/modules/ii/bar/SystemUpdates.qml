import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

MouseArea {
    id: root
    property bool   vertical:    false
    property string lastChecked: "Never"

    implicitWidth:  row.implicitWidth  + 20
    implicitHeight: row.implicitHeight + 20

    readonly property bool hideWhenZero: Config.options.updates?.hideWhenZero ?? false
    readonly property color accentColor:
    Updates.count >= 25 ? Appearance.colors.colError :
    Updates.count >= 10 ? Appearance.colors.colWarning :
    Appearance.colors.colPrimary

    acceptedButtons: Qt.LeftButton | Qt.RightButton
    hoverEnabled:    true

    onReleased: (mouse) => {
        if (mouse.button === Qt.RightButton) {
            Updates.refresh()
            root.lastChecked = Qt.formatDateTime(new Date(), "hh:mm ap")
        }
    }
    onPressed: (mouse) => {
        if (mouse.button === Qt.LeftButton) {
            // Can't do running=false; running=true in one block — QML batches
            // the changes and the net result is running stays true unchanged.
            // Qt.callLater defers the second assignment to the next event loop tick.
            updaterProc.running = false
            Qt.callLater(function() { updaterProc.running = true })
        }
    }

    visible: root.hideWhenZero ? Updates.count > 0 : true

    // ── Popup open/close state ────────────────────────────────────────────────
    // We manage this entirely imperatively so nothing (right-click focus
    // changes, child hover zones, binding re-evaluation) can fight us.
    property bool popupOpen: false

    function openPopup()  { popupCloseTimer.stop();  popupOpen = true  }
    function closePopup() { popupCloseTimer.start() }

    HoverHandler {
        id: barHover
        onHoveredChanged: hovered ? root.openPopup() : root.closePopup()
    }

    Timer {
        id: popupCloseTimer
        interval: 500
        repeat:   false
        onTriggered: root.popupOpen = false
    }

    Timer { interval: 1800000; running: true; repeat: true
        onTriggered: { Updates.refresh(); root.lastChecked = Qt.formatDateTime(new Date(), "hh:mm ap") }
    }
    Component.onCompleted: { Updates.refresh(); root.lastChecked = Qt.formatDateTime(new Date(), "hh:mm ap") }

    // ── Bar widget ────────────────────────────────────────────────────────────
    Row {
        id: row; anchors.centerIn: parent; spacing: 6

        Item {
            id: iconWrapper
            anchors.verticalCenter: parent.verticalCenter
            // Extra padding around the icon to fit the arc ring
            width:  iconSymbol.width  + 6
            height: iconSymbol.height + 6

            SequentialAnimation on y {
                running: Updates.count > 0 && !Updates.checking
                loops:   Animation.Infinite
                NumberAnimation { to: -3; duration: 900; easing.type: Easing.InOutSine }
                NumberAnimation { to:  0; duration: 900; easing.type: Easing.InOutSine }
            }
            NumberAnimation on y {
                running: Updates.checking || Updates.count === 0
                to: 0; duration: 300; easing.type: Easing.OutCubic
            }

            // Dim track ring — always present when checking
            Canvas {
                anchors.fill: parent
                visible: Updates.checking
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    ctx.beginPath()
                    ctx.arc(width/2, height/2, width/2 - 1, 0, Math.PI * 2)
                    ctx.strokeStyle = Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.15)
                    ctx.lineWidth = 2
                    ctx.stroke()
                }
                Connections {
                    target: root
                    function onAccentColorChanged() { parent.requestPaint() }
                }
            }

            // Spinning arc
            Canvas {
                id: barSpinArc
                anchors.fill: parent
                visible: Updates.checking
                opacity: Updates.checking ? 1.0 : 0.0
                Behavior on opacity { NumberAnimation { duration: 200 } }

                property real angle: 0
                onAngleChanged: requestPaint()
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    ctx.beginPath()
                    var r     = width/2 - 1
                    var start = (angle - 90) * Math.PI / 180
                    ctx.arc(width/2, height/2, r, start, start + Math.PI * 1.1)
                    ctx.strokeStyle = Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 1.0)
                    ctx.lineWidth = 2
                    ctx.lineCap  = "round"
                    ctx.stroke()
                }
                Connections {
                    target: root
                    function onAccentColorChanged() { barSpinArc.requestPaint() }
                }
                NumberAnimation on angle {
                    running: Updates.checking
                    from: 0; to: 360; duration: 900; loops: Animation.Infinite
                }
            }

            MaterialSymbol {
                id: iconSymbol
                anchors.centerIn: parent
                iconSize: Appearance.font.pixelSize.large
                color:    root.accentColor

                Behavior on text { }
                property string targetText: Updates.checking ? "autorenew" : "update"
                onTargetTextChanged: iconFade.restart()

                SequentialAnimation {
                    id: iconFade
                    NumberAnimation { target: iconSymbol; property: "opacity"; to: 0; duration: 120; easing.type: Easing.InCubic }
                    ScriptAction    { script: iconSymbol.text = iconSymbol.targetText }
                    NumberAnimation { target: iconSymbol; property: "opacity"; to: 1; duration: 180; easing.type: Easing.OutCubic }
                }

                RotationAnimator on rotation {
                    running: Updates.checking
                    from: 0; to: 360; duration: 1200; loops: Animation.Infinite
                }
                NumberAnimation on rotation {
                    running: !Updates.checking
                    to: 0; duration: 400; easing.type: Easing.OutCubic
                }

                SequentialAnimation {
                    id: arrivalWiggle
                    running: false
                    NumberAnimation { target: iconSymbol; property: "rotation"; to:  12; duration: 80 }
                    NumberAnimation { target: iconSymbol; property: "rotation"; to: -10; duration: 80 }
                    NumberAnimation { target: iconSymbol; property: "rotation"; to:   6; duration: 70 }
                    NumberAnimation { target: iconSymbol; property: "rotation"; to:  -4; duration: 70 }
                    NumberAnimation { target: iconSymbol; property: "rotation"; to:   0; duration: 60 }
                }
            }

            Rectangle {
                id: notifDot
                visible: Updates.count > 0 && !Updates.checking
                width: 8; height: 8; radius: 4
                color: root.accentColor
                anchors { top: parent.top; right: parent.right; topMargin: -2; rightMargin: -2 }

                SequentialAnimation on opacity {
                    running: Updates.count > 0 && !Updates.checking
                    loops:   Animation.Infinite
                    NumberAnimation { to: 0.25; duration: 900; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1.0;  duration: 900; easing.type: Easing.InOutSine }
                }

                transform: Scale {
                    id: dotScale
                    origin.x: notifDot.width  / 2
                    origin.y: notifDot.height / 2
                }
                NumberAnimation { id: dotPop;  target: dotScale; property: "xScale"; from: 0; to: 1; duration: 350; easing.type: Easing.OutBack; running: false }
                NumberAnimation { id: dotPopY; target: dotScale; property: "yScale"; from: 0; to: 1; duration: 350; easing.type: Easing.OutBack; running: false }
                onVisibleChanged: if (visible) { dotPop.restart(); dotPopY.restart() }
            }
        }

        Text {
            id: countLabel
            anchors.verticalCenter: parent.verticalCenter
            visible: Updates.count > 0
            text:    String(Updates.count)
            font.pixelSize: Appearance.font.pixelSize.small
            font.weight:    Font.DemiBold
            color:   root.accentColor
            opacity: Updates.count > 0 ? 1.0 : 0.0
            Behavior on opacity { NumberAnimation { duration: 300 } }

            property int prevCount: 0
            onTextChanged: (text) => { if (parseInt(text) > 0) countSlide.restart() }

            transform: Translate { id: countTranslate }
            SequentialAnimation {
                id: countSlide
                running: false
                ScriptAction { script: { countTranslate.y = 6 } }
                ParallelAnimation {
                    NumberAnimation { target: countTranslate; property: "y";       to: 0; duration: 280; easing.type: Easing.OutCubic }
                    NumberAnimation { target: countLabel;     property: "opacity"; from: 0; to: 1; duration: 280 }
                }
            }
        }
    }

    property int _prevCount: 0
    Connections {
        target: Updates
        function onCountChanged() {
            if (Updates.count > 0 && root._prevCount === 0)
                arrivalWiggle.restart()
                root._prevCount = Updates.count
        }
    }

    // ── Popup ─────────────────────────────────────────────────────────────────
    StyledPopup {
        id: popup
        hoverTarget: root
        open: root.popupOpen || popup.popupHovered
        onPopupHoveredChanged: popupHovered ? root.openPopup() : root.closePopup()

        ColumnLayout {
            anchors.centerIn: parent
            width: 260
            spacing: 10

            StyledPopupHeaderRow {
                Layout.fillWidth: true
                icon: "system_update_alt"; label: Translation.tr("System Updates")
                count: Updates.count; countColor: root.accentColor; timestamp: root.lastChecked
            }

            // Hero status card
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: heroCol.implicitHeight + 22
                radius: Appearance.rounding.normal
                color:  Appearance.m3colors.m3surfaceContainerHigh
                border.width: 1
                border.color: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.40)

                ColumnLayout {
                    id: heroCol; anchors.centerIn: parent; spacing: 4

                    // Icon + spinning arc ring
                    Item {
                        Layout.alignment: Qt.AlignHCenter
                        width: 52; height: 52

                        // Track ring (always visible, dim)
                        Canvas {
                            anchors.fill: parent
                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.clearRect(0, 0, width, height)
                                ctx.beginPath()
                                ctx.arc(width/2, height/2, 22, 0, Math.PI * 2)
                                ctx.strokeStyle = Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.15)
                                ctx.lineWidth = 3
                                ctx.stroke()
                            }
                            Connections {
                                target: root
                                function onAccentColorChanged() { parent.requestPaint() }
                            }
                        }

                        // Spinning arc (only while checking)
                        Canvas {
                            id: spinArc
                            anchors.fill: parent
                            visible: Updates.checking
                            opacity: Updates.checking ? 1.0 : 0.0
                            Behavior on opacity { NumberAnimation { duration: 250 } }

                            property real angle: 0
                            onAngleChanged: requestPaint()
                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.clearRect(0, 0, width, height)
                                ctx.beginPath()
                                var start = (angle - 90) * Math.PI / 180
                                var end   = start + Math.PI * 1.1
                                ctx.arc(width/2, height/2, 22, start, end)
                                ctx.strokeStyle = Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 1.0)
                                ctx.lineWidth = 3
                                ctx.lineCap = "round"
                                ctx.stroke()
                            }
                            Connections {
                                target: root
                                function onAccentColorChanged() { spinArc.requestPaint() }
                            }

                            NumberAnimation on angle {
                                running: Updates.checking
                                from: 0; to: 360; duration: 900; loops: Animation.Infinite
                            }
                        }

                        // Checkmark/done ring fade-in when check completes
                        Canvas {
                            id: doneArc
                            anchors.fill: parent
                            visible: !Updates.checking && Updates.count === 0
                            opacity: visible ? 1.0 : 0.0
                            Behavior on opacity { NumberAnimation { duration: 400 } }
                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.clearRect(0, 0, width, height)
                                ctx.beginPath()
                                ctx.arc(width/2, height/2, 22, 0, Math.PI * 2)
                                ctx.strokeStyle = Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.7)
                                ctx.lineWidth = 3
                                ctx.stroke()
                            }
                            onVisibleChanged: if (visible) requestPaint()
                        }

                        MaterialSymbol {
                            anchors.centerIn: parent
                            text: Updates.checking ? "autorenew" : Updates.count === 0 ? "check_circle" : "update"
                            iconSize: 26; color: root.accentColor
                            RotationAnimator on rotation {
                                running: Updates.checking
                                from: 0; to: 360; duration: 1200; loops: Animation.Infinite
                            }
                            NumberAnimation on rotation {
                                running: !Updates.checking
                                to: 0; duration: 400; easing.type: Easing.OutCubic
                            }
                        }
                    }

                    StyledText {
                        Layout.alignment: Qt.AlignHCenter
                        text: Updates.checking ? Translation.tr("Checking…")
                        : Updates.count === 0 ? Translation.tr("Up to date")
                        : Updates.count + " " + Translation.tr("updates available")
                        font { pixelSize: Appearance.font.pixelSize.normal; weight: Font.DemiBold }
                        color: root.accentColor
                    }
                }
            }

            // Package list
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: Math.min(pkgList.implicitHeight, 130) + 16
                visible: Updates.count > 0
                radius: Appearance.rounding.normal
                color:  Appearance.m3colors.m3surfaceContainerHigh
                border.width: 1
                border.color: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.20)
                clip: true

                StyledFlickable {
                    anchors { fill: parent; margins: 8 }
                    contentHeight: pkgList.implicitHeight; contentWidth: width
                    Column {
                        id: pkgList; width: parent.width; spacing: 4
                        Repeater {
                            model: Updates.packages
                            delegate: RowLayout {
                                required property string modelData
                                width: pkgList.width; spacing: 8
                                Rectangle {
                                    implicitWidth: 24; implicitHeight: 24; radius: 6
                                    color:        Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.15)
                                    border.width: 1
                                    border.color: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.25)
                                    MaterialSymbol { anchors.centerIn: parent; text: "package_2"; iconSize: 12; color: root.accentColor }
                                }
                                StyledText { Layout.fillWidth: true; text: modelData; font.pixelSize: Appearance.font.pixelSize.small; color: Appearance.colors.colOnSurfaceVariant; elide: Text.ElideRight }
                            }
                        }
                    }
                }
            }

            // Action buttons
            RowLayout {
                Layout.fillWidth: true; spacing: 8

                Rectangle {
                    Layout.fillWidth: true; implicitHeight: refreshRow.implicitHeight + 14
                    radius: Appearance.rounding.small
                    color:  refreshHover.hovered ? Appearance.m3colors.m3surfaceContainerHighest : Appearance.m3colors.m3surfaceContainerHigh
                    border.width: 1; border.color: Qt.rgba(Appearance.colors.colPrimary.r, Appearance.colors.colPrimary.g, Appearance.colors.colPrimary.b, 0.25)
                    Behavior on color { ColorAnimation { duration: 150 } }
                    HoverHandler { id: refreshHover }
                    RowLayout {
                        id: refreshRow; anchors.centerIn: parent; spacing: 6
                        MaterialSymbol {
                            text: "refresh"; iconSize: Appearance.font.pixelSize.normal; color: Appearance.colors.colOnLayer1
                            RotationAnimator on rotation { running: Updates.checking; from: 0; to: 360; duration: 1000; loops: Animation.Infinite }
                        }
                        StyledText { text: Updates.checking ? Translation.tr("Checking…") : Translation.tr("Refresh"); font.pixelSize: Appearance.font.pixelSize.small; color: Appearance.colors.colOnLayer1 }
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: { Updates.refresh(); root.lastChecked = Qt.formatDateTime(new Date(), "hh:mm ap") }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true; implicitHeight: updateRow.implicitHeight + 14
                    visible: Updates.count > 0; radius: Appearance.rounding.small
                    color:  updateHover.hovered
                    ? Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.30)
                    : Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.18)
                    border.width: 1; border.color: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.55)
                    Behavior on color { ColorAnimation { duration: 150 } }
                    HoverHandler { id: updateHover }
                    RowLayout {
                        id: updateRow; anchors.centerIn: parent; spacing: 6
                        MaterialSymbol { text: "download"; iconSize: Appearance.font.pixelSize.normal; color: root.accentColor }
                        StyledText { text: Translation.tr("Update"); font { pixelSize: Appearance.font.pixelSize.small; weight: Font.DemiBold } color: root.accentColor }
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: { updaterProc.running = false; updaterProc.running = true }
                    }
                }
            }

            StyledText {
                Layout.alignment: Qt.AlignHCenter
                text: Translation.tr("Left-click to update  •  Right-click to refresh")
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colSubtext; opacity: 0.5
            }
        }
    }

    // ── Updater process ───────────────────────────────────────────────────────
    Process {
        id: updaterProc
        running: false
        command: ["/usr/bin/kitty", "-e", "/usr/bin/arch-update"]
        // Quickshell Process has no onExited — use onRunningChanged instead.
        // When running becomes false the process has ended naturally.
        onRunningChanged: {
            if (!running) postUpdateTimer.restart()
        }
    }

    Timer {
        id: postUpdateTimer
        interval: 1500
        repeat:   false
        onTriggered: {
            Updates.refresh()
            root.lastChecked = Qt.formatDateTime(new Date(), "hh:mm ap")
        }
    }
}
