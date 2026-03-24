import qs.modules.common
import qs.modules.common.models
import qs.modules.common.functions
import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
pragma Singleton
pragma ComponentBehavior: Bound

/**
 * Provides a list of wallpapers and an "apply" action that calls the existing
 * switchwall.sh script. Pretty much a limited file browsing service.
 */
Singleton {
    id: root

    property string thumbgenScriptPath: `${FileUtils.trimFileProtocol(Directories.scriptPath)}/thumbnails/thumbgen-venv.sh`
    property string generateThumbnailsMagickScriptPath: `${FileUtils.trimFileProtocol(Directories.scriptPath)}/thumbnails/generate-thumbnails-magick.sh`
    property alias directory: folderModel.folder
    readonly property string effectiveDirectory: FileUtils.trimFileProtocol(folderModel.folder.toString())
    property url defaultFolder: Qt.resolvedUrl("file://" + FileUtils.trimFileProtocol(Directories.pictures) + "/Wallpapers")
    property alias folderModel: folderModel // Expose for direct binding when needed
    property string searchQuery: ""
    readonly property list<string> extensions: [ // TODO: add videos
    "jpg", "jpeg", "png", "webp", "avif", "bmp", "svg", "mp4", "mkv", "webm", "avi", "mov", "m4v", "ogv"
    ]
    property list<string> wallpapers: [] // List of absolute file paths (without file://)
    readonly property bool thumbnailGenerationRunning: thumbgenProc.running
    property real thumbnailGenerationProgress: 0

    property int crossfadeDuration: 600
    // Path to the per-monitor state directory written by fetchwall.sh
    readonly property string monitorStateDir: `${FileUtils.trimFileProtocol(Directories.state)}/user/generated/wallpaper/monitors`
    readonly property string fetchwallScriptPath: `${FileUtils.trimFileProtocol(Directories.scriptPath)}/fetchwall.sh`

    signal changed()
    signal aboutToChange(string newPath)
    signal thumbnailGenerated(directory: string)
    signal thumbnailGeneratedFile(filePath: string)

    function load () {} // For forcing initialization

    property list<string> videoExtensions: [
        "mp4", "mkv", "webm", "avi", "mov", "m4v", "ogv"
    ]
    function isVideoFile(name) {
        return videoExtensions.some(ext => name.endsWith("." + ext))
    }

    // Executions
    Process {
        id: applyProc
    }

    Connections {
        target: Config
        function onReadyChanged() { // Apply wallpaper on config ready if it's a video
            if (!Config.ready || !root.isVideoFile(Config.options.background.wallpaperPath.toLowerCase())) return;
            root.apply(Config.options.background.wallpaperPath, Appearance.m3colors.darkmode);
        }
    }

    function openFallbackPicker(darkMode = Appearance.m3colors.darkmode) {
        applyProc.exec([
            Directories.wallpaperSwitchScriptPath,
            "--mode", (darkMode ? "dark" : "light")
        ])
    }

    function apply(path, darkMode = Appearance.m3colors.darkmode, monitor = "") {
        if (!path || path.length === 0) return
            root.aboutToChange(path)
            const args = [
                Directories.wallpaperSwitchScriptPath,
                "--image", path,
                "--mode", (darkMode ? "dark" : "light")
            ]
            if (monitor && monitor.length > 0) {
                args.push("--monitor", monitor)
                args.push("--no-save")
            }
            applyProc.exec(args)
            root.changed()
    }

    // Fetch a unique random wallpaper for every connected monitor
    function fetchPerMonitor(darkMode = Appearance.m3colors.darkmode) {
        applyProc.exec([
            "bash", root.fetchwallScriptPath,
            "--mode", (darkMode ? "dark" : "light")
        ])
        root.changed()
    }

    Process {
        id: selectProc
        property string filePath: ""
        property bool darkMode: Appearance.m3colors.darkmode
        function select(filePath, darkMode = Appearance.m3colors.darkmode) {
            selectProc.filePath = filePath
            selectProc.darkMode = darkMode
            selectProc.exec(["test", "-d", FileUtils.trimFileProtocol(filePath)])
        }
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0) {
                setDirectory(selectProc.filePath);
                return;
            }
            root.apply(selectProc.filePath, selectProc.darkMode);
        }
    }

    function select(filePath, darkMode = Appearance.m3colors.darkmode) {
        selectProc.select(filePath, darkMode);
    }

    function randomFromCurrentFolder(darkMode = Appearance.m3colors.darkmode) {
        if (folderModel.count === 0) return;
        const randomIndex = Math.floor(Math.random() * folderModel.count);
        const filePath = folderModel.get(randomIndex, "filePath");
        print("Randomly selected wallpaper:", filePath);
        root.select(filePath, darkMode);
    }

    Process {
        id: validateDirProc
        property string nicePath: ""
        function setDirectoryIfValid(path) {
            validateDirProc.nicePath = FileUtils.trimFileProtocol(path).replace(/\/+$/, "")
            if (/^\/*$/.test(validateDirProc.nicePath)) validateDirProc.nicePath = "/";
            validateDirProc.exec([
                "bash", "-c",
                `if [ -d "$1" ]; then echo dir; elif [ -f "$1" ]; then echo file; else echo invalid; fi`,
                "_", validateDirProc.nicePath
            ])
        }
        stdout: StdioCollector {
            onStreamFinished: {
                root.directory = Qt.resolvedUrl(validateDirProc.nicePath)
                const result = text.trim()
                if (result === "dir") {
                } else if (result === "file") {
                    root.directory = Qt.resolvedUrl(FileUtils.parentDirectory(validateDirProc.nicePath))
                } else {
                    // Ignore
                }
            }
        }
    }
    function setDirectory(path) {
        validateDirProc.setDirectoryIfValid(path)
    }
    function navigateUp() {
        folderModel.navigateUp()
    }
    function navigateBack() {
        folderModel.navigateBack()
    }
    function navigateForward() {
        folderModel.navigateForward()
    }

    // Folder model
    FolderListModelWithHistory {
        id: folderModel
        folder: Qt.resolvedUrl(root.defaultFolder)
        caseSensitive: false
            nameFilters: {
                const terms = searchQuery.split(" ").filter(s => s.length > 0);
                if (terms.length === 0) {
                    return root.extensions.map(ext => `*.${ext}`);
                }
                return root.extensions.flatMap(ext => terms.map(s => `*${s}*.${ext}`));
            }
            showDirs: true
            showDotAndDotDot: false
            showOnlyReadable: true
            sortField: FolderListModel.Time
            sortReversed: false
            onCountChanged: {
                const paths = []
                for (let i = 0; i < folderModel.count; i++) {
                    const path = folderModel.get(i, "filePath") || FileUtils.trimFileProtocol(folderModel.get(i, "fileURL"))
                    if (path && path.length) paths.push(path)
                }
                root.wallpapers = paths
            }
    }

    // Thumbnail generation
    function generateThumbnail(size: string) {
        if (!["normal", "large", "x-large", "xx-large"].includes(size)) throw new Error("Invalid thumbnail size");
        const dir = FileUtils.trimFileProtocol(root.directory.toString());
        if (!dir || dir.length === 0) return;
        thumbgenProc.directory = root.directory
        thumbgenProc.running = false
        const escapedDir = dir.replace(/'/g, "'\\''");
        thumbgenProc.command = [
            "bash", "-c",
            `'${thumbgenScriptPath}' --size '${size}' --machine_progress -d '${escapedDir}' 2>/dev/null || '${generateThumbnailsMagickScriptPath}' --size '${size}' -d '${escapedDir}' 2>/dev/null`,
        ]
        // console.log("[Wallpapers] Generating thumbnails:", thumbgenProc.command[2])
        root.thumbnailGenerationProgress = 0
        thumbgenProc.running = true
    }
    Process {
        id: thumbgenProc
        property string directory
        stdout: SplitParser {
            // Note: We are NOT using the 'split' property here to avoid the crash you had earlier
            onRead: data => {
                const lines = data.split("\n");
                for (var i = 0; i < lines.length; i++) {
                    const line = lines[i].trim();
                    if (!line) continue;

                    // DEBUG: Un-comment this to see exactly what the script is saying in your terminal
                    // console.log("THUMBGEN OUTPUT:", line);

                    let progressMatch = line.match(/^PROGRESS (\d+)\/(\d+) FILE (.+)$/);
                    if (progressMatch) {
                        root.thumbnailGenerationProgress = parseInt(progressMatch[1]) / parseInt(progressMatch[2]);
                        root.thumbnailGeneratedFile(progressMatch[3].trim());
                    } else {
                        let fileMatch = line.match(/^FILE (.+)$/);
                        if (fileMatch) {
                            root.thumbnailGeneratedFile(fileMatch[1].trim());
                        }
                    }
                }
            }
        }
        onExited: (exitCode, exitStatus) => {
            root.thumbnailGenerated(thumbgenProc.directory)
        }
    }

    IpcHandler {
        target: "wallpapers"

        function apply(path: string): void {
            root.apply(path);
        }
        function applyToMonitor(path: string, monitor: string): void {
            root.apply(path, Appearance.m3colors.darkmode, monitor);
        }
        function fetchPerMonitor(): void {
            root.fetchPerMonitor();
        }
    }
}
