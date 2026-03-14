import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

ContentPage {
    id: page
    readonly property int index: 0
    property bool register: parent.register ?? false
    forceWidth: true

        property bool allowHeavyLoad: false
        Component.onCompleted: Qt.callLater(() => page.allowHeavyLoad = true)

        Process {
            id: fetchwallProc
            stdout: SplitParser { onRead: data => console.log("[fetchwall stdout]", data) }
            stderr: SplitParser { onRead: data => console.log("[fetchwall stderr]", data) }
            onExited: (code, status) => {
                console.log("[fetchwall] exited code=" + code)
                monitorPreviewsContainer.refreshCount++
            }
        }

        Process {
            id: osuWallProc
            stdout: SplitParser { onRead: data => console.log("[osuwall stdout]", data) }
            stderr: SplitParser { onRead: data => console.log("[osuwall stderr]", data) }
            onExited: (code, status) => {
                console.log("[osuwall] exited code=" + code)
                monitorPreviewsContainer.refreshCount++
            }
        }

        component SmallLightDarkPreferenceButton: RippleButton {
            id: smallLightDarkPreferenceButton
            required property bool dark
            property color colText: enabled
            ? toggled
            ? Appearance.colors.colOnPrimary
            : Appearance.colors.colOnLayer2
            : Appearance.colors.colOnLayer3

            padding: 5
            Layout.fillWidth: true
            toggled: Appearance.m3colors.darkmode === dark
            colBackground: Appearance.colors.colLayer2

            onClicked: {
                Quickshell.execDetached([
                    "bash",
                    "-c",
                    `${Directories.wallpaperSwitchScriptPath} --mode ${dark ? "dark" : "light"} --noswitch`
                ])
            }

            StyledToolTip {
                extraVisibleCondition: !smallLightDarkPreferenceButton.enabled
                text: Translation.tr("Custom color scheme has been selected")
            }

            contentItem: Item {
                anchors.centerIn: parent

                RowLayout {
                    anchors.centerIn: parent
                    spacing: 10

                    MaterialSymbol {
                        Layout.alignment: Qt.AlignHCenter
                        iconSize: 30
                        text: dark ? "dark_mode" : "light_mode"
                        fill: toggled ? 1 : 0
                        color: smallLightDarkPreferenceButton.colText
                    }

                    StyledText {
                        Layout.alignment: Qt.AlignHCenter
                        text: dark ? Translation.tr("Dark") : Translation.tr("Light")
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: smallLightDarkPreferenceButton.colText
                    }
                }
            }
        }

        ContentSection {
            icon: "format_paint"
            title: Translation.tr("Wallpaper & Colors")
            Layout.fillWidth: true

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 10

                Item {
                    id: monitorPreviewsContainer
                    Layout.fillWidth: true
                    implicitHeight: 180

                    readonly property string monitorStateDir: Wallpapers.monitorStateDir
                    property int refreshCount: 0

                    property var monitorNames: []

                    Process {
                        id: monitorQueryProc
                        command: ["bash","-c","hyprctl monitors -j | jq -r '.[].name'"]

                        stdout: SplitParser {
                            onRead: data => {
                                var lines = data.split("\n")
                                for (var i = 0; i < lines.length; i++) {
                                    var name = lines[i].trim()
                                    if (name.length > 0 &&
                                        monitorPreviewsContainer.monitorNames.indexOf(name) === -1) {
                                        monitorPreviewsContainer.monitorNames =
                                        [...monitorPreviewsContainer.monitorNames, name]
                                        }
                                }
                            }
                        }

                        Component.onCompleted: running = true
                    }

                    property var displayMonitors:
                    monitorNames.length > 0 ? monitorNames : [""]



                    Row {
                        anchors.fill: parent
                        spacing: 8

                        Repeater {
                            id: tileRepeater
                            model: monitorPreviewsContainer.displayMonitors

                            delegate: Item {
                                id: monitorTile
                                required property string modelData
                                required property int index

                                readonly property bool isFallback: modelData === ""

                                readonly property string stateFile:
                                isFallback ? ""
                                : monitorPreviewsContainer.monitorStateDir
                                + "/" + modelData + ".json"

                                property string wallpaperPath: ""

                                Process {
                                    id: stateReader
                                    command: ["bash", "-c", "cat '" + monitorTile.stateFile + "'"]
                                    stdout: StdioCollector {
                                        onStreamFinished: {
                                            try {
                                                var d = JSON.parse(text)
                                                var p = d.path || ""
                                                if (p.length > 0) {
                                                    if (!p.startsWith("file://")) p = "file://" + p
                                                        monitorTile.wallpaperPath = p
                                                }
                                            } catch(e) {}
                                        }
                                    }
                                    Component.onCompleted: {
                                        if (monitorTile.stateFile.length > 0) running = true
                                    }
                                }
                                FileView {
                                    id: stateWatcher
                                    path: monitorTile.stateFile
                                    watchChanges: true
                                    onTextChanged: {
                                        try {
                                            var d = JSON.parse(text)
                                            var p = d.path || ""
                                            if (p.length > 0) {
                                                if (!p.startsWith("file://")) p = "file://" + p
                                                    monitorTile.wallpaperPath = p
                                            }
                                        } catch(e) {}
                                    }
                                }
                                Connections {
                                    target: Wallpapers
                                    function onChanged() {
                                        tileRefreshTimer.restart()
                                    }
                                }
                                Connections {
                                    target: monitorPreviewsContainer
                                    function onRefreshCountChanged() {
                                        stateReader.running = false
                                        stateReader.running = true
                                    }
                                }
                                Timer {
                                    id: tileRefreshTimer
                                    interval: 2500
                                    repeat: false
                                    onTriggered: {
                                        stateReader.running = false
                                        stateReader.running = true
                                    }
                                }

                                width:
                                (monitorPreviewsContainer.width
                                - 8 * Math.max(monitorPreviewsContainer.displayMonitors.length - 1,0))
                                / Math.max(monitorPreviewsContainer.displayMonitors.length,1)

                                height: monitorPreviewsContainer.implicitHeight

                                StyledImage {
                                    anchors.fill: parent
                                    sourceSize.width: parent.width
                                    sourceSize.height: parent.height
                                    fillMode: Image.PreserveAspectCrop
                                    source: monitorTile.wallpaperPath
                                    cache: false

                                    layer.enabled: true
                                    layer.effect: OpacityMask {
                                        maskSource: Rectangle {
                                            width: monitorTile.width
                                            height: monitorTile.height
                                            radius: Appearance.rounding.normal
                                        }
                                    }

                                    RippleButton {
                                        anchors.fill: parent
                                        colBackground: "transparent"

                                        colBackgroundHover:
                                        ColorUtils.transparentize(
                                            Appearance.colors.colOnPrimary,
                                            0.85
                                        )

                                        colRipple:
                                        ColorUtils.transparentize(
                                            Appearance.colors.colOnPrimary,
                                            0.5
                                        )

                                        onClicked: {
                                            if (monitorTile.isFallback) {
                                                Wallpapers.openFallbackPicker(
                                                    Appearance.m3colors.darkmode
                                                )
                                            } else {
                                                switchProc.monitor = monitorTile.modelData
                                                    switchProc.running = true
                                            }
                                        }
                                    }
                                }

                                MaterialSymbol {
                                    anchors.centerIn: parent
                                    text: "hourglass_top"
                                    color: Appearance.colors.colPrimary
                                    iconSize: 32
                                    z: -1
                                }

                                Process {
                                    id: switchProc
                                    property string monitor: ""
                                    command: [
                                        Directories.wallpaperSwitchScriptPath,
                                        "--monitor", monitor
                                    ]
                                    onExited: (code, status) => {
                                        stateReader.running = false
                                        stateReader.running = true
                                    }
                                }

                                // Monitor name — TOP LEFT
                                Rectangle {
                                    anchors {
                                        left: parent.left
                                        top: parent.top
                                        margins: 8
                                    }
                                    implicitWidth: Math.min(monBadge.implicitWidth + 16, parent.width - 16)
                                    implicitHeight: monBadge.implicitHeight + 6
                                    color: Appearance.colors.colPrimary
                                    radius: Appearance.rounding.full
                                    visible: !monitorTile.isFallback
                                    StyledText {
                                        id: monBadge
                                        anchors.centerIn: parent
                                        text: monitorTile.modelData
                                        color: Appearance.colors.colOnPrimary
                                        font.pixelSize: Appearance.font.pixelSize.smaller
                                    }
                                }

                                // Filename — BOTTOM CENTER
                                Rectangle {
                                    anchors {
                                        bottom: parent.bottom
                                        horizontalCenter: parent.horizontalCenter
                                        margins: 8
                                    }
                                    implicitWidth: Math.min(fileBadge.implicitWidth + 16, parent.width - 16)
                                    implicitHeight: fileBadge.implicitHeight + 6
                                    color: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.3)
                                    radius: Appearance.rounding.full
                                    visible: monitorTile.wallpaperPath.length > 0
                                    StyledText {
                                        id: fileBadge
                                        anchors.centerIn: parent
                                        property string fn: monitorTile.wallpaperPath.replace("file://", "").split("/").pop()
                                        text: fn.length > 22 ? fn.slice(0, 19) + "..." : fn
                                        color: Appearance.colors.colOnPrimary
                                        font.pixelSize: Appearance.font.pixelSize.smaller
                                    }
                                }
                            }
                        }
                    }
                }



                ColumnLayout {
                    Layout.fillWidth: true

                    RowLayout {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.fillWidth: true
                        Layout.preferredHeight: 60
                        uniformCellSizes: true

                        SmallLightDarkPreferenceButton {
                            Layout.preferredHeight: 60
                            dark: false
                            enabled: Config.options.appearance.palette.type.startsWith("scheme")
                        }
                        SmallLightDarkPreferenceButton {
                            Layout.preferredHeight: 60
                            dark: true
                            enabled: Config.options.appearance.palette.type.startsWith("scheme")
                        }
                    }



                    Item {
                        id: colorGridItem
                        z: 1
                        Layout.fillWidth: true
                        implicitHeight: 180
                        readonly property bool mediaModeEnabled: Persistent.states.background.mediaMode.enabled

                        Loader {
                            z: 1
                            anchors.top: parent.top
                            anchors.topMargin: 60
                            anchors.horizontalCenter: parent.horizontalCenter
                            active: colorGridItem.mediaModeEnabled
                            sourceComponent: StyledText {
                                text: Translation.tr("Media mode enabled")
                                font.pixelSize: Appearance.font.pixelSize.large
                            }
                        }


                        Loader {
                            anchors.fill: parent
                            active: colorGridItem.mediaModeEnabled
                            sourceComponent: Rectangle {
                                anchors.fill: parent
                                opacity: 0.5
                                color: Appearance.colors.colSecondaryContainer
                                radius: Appearance.rounding.small
                            }
                        }


                        StyledFlickable {
                            id: flickable
                            anchors.fill: parent
                            contentHeight: contentLayout.implicitHeight
                            contentWidth: width
                            clip: true
                            enabled: !colorGridItem.mediaModeEnabled


                            ColumnLayout {
                                id: contentLayout
                                width: flickable.width

                                Repeater {
                                    model: [
                                        { customTheme: false, builtInTheme: false },
                                        { customTheme: false, builtInTheme: true },
                                        { customTheme: true, builtInTheme: false }
                                    ]

                                    delegate: ColorPreviewGrid {
                                        customTheme: modelData.customTheme
                                        builtInTheme: modelData.builtInTheme
                                    }
                                }

                            }
                        }
                    }


                }
            }


            ConfigRow {
                uniform: true
                Layout.fillWidth: true

                RippleButtonWithIcon {
                    enabled: !fetchwallProc.running
                    visible: true
                    Layout.fillWidth: true
                    buttonRadius: Appearance.rounding.small
                    materialIcon: "ifl"
                    mainText: fetchwallProc.running ? Translation.tr("Be patient...") : Translation.tr("Random: Konachan")
                    onClicked: {
                        fetchwallProc.exec(["bash", FileUtils.trimFileProtocol(`${Directories.scriptPath}/colors/random/random_konachan_wall.sh`)])
                    }
                    StyledToolTip {
                        text: Translation.tr("Random wallpaper per monitor from Konachan\nEach monitor gets a unique image")
                    }
                }
                RippleButtonWithIcon {
                    enabled: !osuWallProc.running
                    visible: true
                    Layout.fillWidth: true
                    buttonRadius: Appearance.rounding.small
                    materialIcon: "ifl"
                    mainText: osuWallProc.running ? Translation.tr("Be patient...") : Translation.tr("Random: osu! seasonal")
                    onClicked: {
                        osuWallProc.exec(["bash", FileUtils.trimFileProtocol(`${Directories.scriptPath}/colors/random/random_osu_wall.sh`)])
                    }
                    StyledToolTip {
                        text: Translation.tr("Random osu! seasonal background\nImage is saved to ~/Pictures/Wallpapers")
                    }
                }
            }
            ConfigSwitch {
                buttonIcon: "ev_shadow"
                text: Translation.tr("Transparency")
                checked: Config.options.appearance.transparency.enable
                onCheckedChanged: {
                    Config.options.appearance.transparency.enable = checked;
                }
            }

        }



        ContentSection {
            icon: "screenshot_monitor"
            title: Translation.tr("Bar & screen")
            Layout.topMargin: -25



            ConfigRow {
                ContentSubsection {
                    title: Translation.tr("Bar position")
                    ConfigSelectionArray {
                        currentValue: (Config.options.bar.bottom ? 1 : 0) | (Config.options.bar.vertical ? 2 : 0)
                        onSelected: newValue => {
                            Config.options.bar.bottom = (newValue & 1) !== 0;
                            Config.options.bar.vertical = (newValue & 2) !== 0;
                        }
                        options: [
                            {
                                displayName: Translation.tr("Top"),
                                icon: "arrow_upward",
                                value: 0 // bottom: false, vertical: false
                            },
                            {
                                displayName: Translation.tr("Left"),
                                icon: "arrow_back",
                                value: 2 // bottom: false, vertical: true
                            },
                            {
                                displayName: Translation.tr("Bottom"),
                                icon: "arrow_downward",
                                value: 1 // bottom: true, vertical: false
                            },
                            {
                                displayName: Translation.tr("Right"),
                                icon: "arrow_forward",
                                value: 3 // bottom: true, vertical: true
                            }
                        ]
                    }
                }
                ContentSubsection {
                    title: Translation.tr("Bar style")

                    ConfigSelectionArray {
                        currentValue: Config.options.bar.cornerStyle
                        onSelected: newValue => {
                            Config.options.bar.cornerStyle = newValue; // Update local copy
                        }
                        options: [
                            {
                                displayName: Translation.tr("Hug"),
                                icon: "line_curve",
                                value: 0
                            },
                            {
                                displayName: Translation.tr("Float"),
                                icon: "page_header",
                                value: 1
                            },
                            {
                                displayName: Translation.tr("Rect"),
                                icon: "toolbar",
                                value: 2
                            }
                        ]
                    }
                }
            }

            ConfigRow {
                ContentSubsection {
                    title: Translation.tr("Screen round corner")

                    ConfigSelectionArray {
                        register: true
                        currentValue: Config.options.appearance.fakeScreenRounding
                        onSelected: newValue => {
                            Config.options.appearance.fakeScreenRounding = newValue;
                        }
                        options: [
                            {
                                displayName: Translation.tr("No"),
                                icon: "close",
                                value: 0
                            },
                            {
                                displayName: Translation.tr("Yes"),
                                icon: "check",
                                value: 1
                            },
                            {
                                displayName: Translation.tr("When not fullscreen"),
                                icon: "fullscreen_exit",
                                value: 2
                            },
                            {
                                displayName: Translation.tr("Wrapped"),
                                icon: "capture",
                                value: 3
                            }
                        ]
                    }
                }

            }

            ConfigSpinBox {
                visible: Config.options.appearance.fakeScreenRounding === 3
                icon: "line_weight"
                text: Translation.tr("Wrapped frame thickness")
                value: Config.options.appearance.wrappedFrameThickness
                from: 5
                to: 25
                stepSize: 1
                onValueChanged: {
                    Config.options.appearance.wrappedFrameThickness = value;
                }
            }

            ContentSubsection {
                title: Translation.tr("Bar background style")
                tooltip: Translation.tr("Adaptive style makes the bar background transparent when there are no active windows")
                Layout.fillWidth: false

                ConfigSelectionArray {
                    register: true
                    currentValue: Config.options.bar.barBackgroundStyle
                    onSelected: newValue => {
                        Config.options.bar.barBackgroundStyle = newValue;
                    }
                    options: [
                        {
                            displayName: Translation.tr("Visible"),
                            icon: "visibility",
                            value: 1
                        },
                        {
                            displayName: Translation.tr("Adaptive"),
                            icon: "masked_transitions",
                            value: 2
                        },
                        {
                            displayName: Translation.tr("Transparent"),
                            icon: "opacity",
                            value: 0
                        }
                    ]
                }
            }
        }




        NoticeBox {
            Layout.fillWidth: true
            Layout.topMargin: -20
            text: Translation.tr('Not all options are available in this app. You should also check the config file by hitting the "Config file" button on the topleft corner or opening ~/.config/illogical-impulse/config.json manually.')

            RippleButtonWithIcon {
                id: copyPathButton
                property bool justCopied: false
                buttonRadius: Appearance.rounding.small
                materialIcon: justCopied ? "check" : "content_copy"
                mainText: justCopied ? Translation.tr("Path copied") : Translation.tr("Copy path")
                onClicked: {
                    copyPathButton.justCopied = true
                    Quickshell.clipboardText = FileUtils.trimFileProtocol(`${Directories.config}/illogical-impulse/config.json`);
                    revertTextTimer.restart();
                }
                colBackground: ColorUtils.transparentize(Appearance.colors.colPrimaryContainer)
                colBackgroundHover: Appearance.colors.colPrimaryContainerHover
                colRipple: Appearance.colors.colPrimaryContainerActive

                Timer {
                    id: revertTextTimer
                    interval: 1500
                    onTriggered: {
                        copyPathButton.justCopied = false
                    }
                }
            }
        }
}
