import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions


RippleButton {
    id: root
    readonly property string builtInThemeDirectory: Directories.defaultThemes
    readonly property string customThemeDirectory: Directories.customThemes

    property string colorScheme: "scheme-auto"
    property string colorSchemeDisplayName: ""

    property bool builtInTheme: false
    readonly property string builtInThemeFilePath: builtInThemeDirectory + "/" + colorScheme + ".json"
    readonly property string builtInThemeCommand: `jq -r '.primary, .primary_container, .secondary' '${builtInThemeFilePath}'`

    property bool customTheme: false
    readonly property string customThemeFilePath: customThemeDirectory + "/" + colorScheme + ".json"
    readonly property string customThemeCommand: `jq -r '.primary, .primary_container, .secondary' '${customThemeFilePath}'`

    property color accentColor
    readonly property bool toggled: Config.options.appearance.palette.type === root.colorScheme

    readonly property string scriptPath: FileUtils.trimFileProtocol(`${Directories.scriptPath}/colors/generate_colors_material.py`)

    // Wallpaper scheme preview: run generate_colors_material with the current wallpaper
    // and extract primary/primaryContainer/secondary from SCSS output ($varname: #hex;)
    readonly property string wallpaperPreviewCommand:
        `WALL="${Config.options.background.wallpaperPath}"; ` +
        `[[ -z "$WALL" ]] && WALL=$(swww query 2>/dev/null | grep -o 'image: .*' | head -1 | sed 's/^image: //'); ` +
        `"$HOME/.local/state/quickshell/.venv/bin/python3" "${root.scriptPath}" --path "$WALL" --scheme ${root.colorScheme === "scheme-auto" ? "scheme-tonal-spot" : root.colorScheme} 2>/dev/null ` +
        `| grep -E '^\\$(primary|primaryContainer|secondary):' | grep -oE '#[0-9A-Fa-f]{6}'`

    property color primaryColor: "transparent"
    property color secondaryColor: "transparent"
    property color tertiaryColor: "transparent"

    property bool loaded: false
    property bool shouldLoad: false

    signal deleteRequested(string schemeName)

    colBackground: toggled ? Appearance.colors.colPrimaryContainer : Appearance.colors.colLayer2
    colBackgroundHover: toggled ? Appearance.colors.colPrimaryContainerHover : Appearance.colors.colLayer2Hover
    colRipple: toggled ? Appearance.colors.colPrimaryContainerActive : Appearance.colors.colLayer2Active

    buttonRadius: Appearance.rounding.small

    Layout.fillWidth: true
    implicitHeight: 64

    onClicked: {
        Config.options.appearance.palette.type = root.colorScheme;
        if (customTheme) {
            Quickshell.execDetached([Directories.applyCustomThemeScriptPath, root.customThemeFilePath]);
        } else if (builtInTheme) {
            Quickshell.execDetached([Directories.applyCustomThemeScriptPath, root.builtInThemeFilePath]);
        } else {
            Quickshell.execDetached(["bash", "-c",
                `WALL='${Config.options.background.wallpaperPath}'; ` +
                `[[ -z "$WALL" ]] && WALL=$(swww query 2>/dev/null | grep -o 'image: .*' | head -1 | sed 's/^image: //'); ` +
                `${Directories.wallpaperSwitchScriptPath} --noswitch --image "$WALL" --type ${root.colorScheme}`
            ]);
        }
    }

    property var effectiveCommand: root.customTheme ? root.customThemeCommand : root.builtInTheme ? root.builtInThemeCommand : root.wallpaperPreviewCommand

    onShouldLoadChanged: {
        if (shouldLoad && !loaded) {
            colorFetchProccess.running = true
        }
    }

    Process {
        id: colorFetchProccess
        running: false
        command: [ "bash", "-c", root.effectiveCommand ]
        stdout: StdioCollector {
            onStreamFinished: {
                const colors = this.text.split("\n")
                root.primaryColor   = colors[0]?.trim()
                root.secondaryColor = colors[1]?.trim()
                root.tertiaryColor  = colors[2]?.trim()
                root.loaded = true;
                myCanvas.requestPaint()
            }
        }
    }

    StyledToolTip {
        text: root.colorSchemeDisplayName
    }

    Item {
        id: myRect
        anchors.fill: parent

        StyledText {
            anchors.fill: parent
            visible: !root.loaded
            elide: Text.ElideRight
            text: root.colorSchemeDisplayName
            horizontalAlignment: Text.AlignHCenter
            color: Appearance.colors.colOnPrimaryContainer
            font.pixelSize: Appearance.font.pixelSize.small
        }

        Canvas {
            id: myCanvas
            anchors {
                centerIn: parent
                margins: 8
            }
            implicitWidth: root.implicitHeight - 16
            implicitHeight: root.implicitHeight - 16

            antialiasing: true

            onPaint: {
                var ctx = getContext("2d");
                var centerX = width / 2;
                var centerY = height / 2;
                var radius = width / 2;

                ctx.reset();
                ctx.beginPath();
                ctx.fillStyle = root.primaryColor;
                ctx.moveTo(centerX, centerY);

                ctx.arc(centerX, centerY, radius, Math.PI, 0, false);
                ctx.closePath();
                ctx.fill();

                ctx.beginPath();
                ctx.fillStyle = root.secondaryColor;
                ctx.moveTo(centerX, centerY);
                ctx.arc(centerX, centerY, radius, 0, Math.PI / 2, false);
                ctx.closePath();
                ctx.fill();

                ctx.beginPath();
                ctx.fillStyle = root.tertiaryColor;
                ctx.moveTo(centerX, centerY);
                ctx.arc(centerX, centerY, radius, Math.PI / 2, Math.PI, false);
                ctx.closePath();
                ctx.fill();
            }
        }

        // Delete button — only shown on custom themes
        Loader {
            active: root.customTheme
            anchors { top: parent.top; right: parent.right; margins: 4 }
            sourceComponent: Rectangle {
                width: 20; height: 20; radius: 10
                color: deleteHover.hovered
                ? Qt.rgba(Appearance.colors.colError.r, Appearance.colors.colError.g, Appearance.colors.colError.b, 0.85)
                : Qt.rgba(Appearance.colors.colError.r, Appearance.colors.colError.g, Appearance.colors.colError.b, 0.55)
                Behavior on color { ColorAnimation { duration: 120 } }
                HoverHandler { id: deleteHover }
                MaterialSymbol { anchors.centerIn: parent; text: "close"; iconSize: 12; color: "white" }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: (e) => { e.accepted = true; root.deleteRequested(root.colorScheme) }
                }
            }
        }
    }
}
