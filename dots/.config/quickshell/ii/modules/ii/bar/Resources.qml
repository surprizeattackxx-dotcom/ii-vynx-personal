import qs.modules.common
import qs.services
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

MouseArea {
    id: root
    implicitWidth: rowLayout.implicitWidth + rowLayout.anchors.leftMargin + rowLayout.anchors.rightMargin
    implicitHeight: Appearance.sizes.barHeight
    hoverEnabled: !Config.options.bar.tooltips.clickToShow

    // ── Disk usage (shell-backed) ─────────────────────────────────────────────
    property real diskPercentage: 0.0

    QtObject {
        id: diskBackend

        property var diskProc: Process {
            command: ["bash", "-c", "df -k / | awk 'NR==2{print $2, $3}'"]
            running: true
            stdout: SplitParser {
                onRead: (line) => {
                    const parts = line.trim().split(" ");
                    const total = parseInt(parts[0]);
                    const used  = parseInt(parts[1]);
                    root.diskPercentage = used / total;
                }
            }
        }

        property var diskTimer: Timer {
            interval: 10000; repeat: true; running: true
            onTriggered: diskBackend.diskProc.running = true
        }
    }

    // ── GPU usage (shell-backed) ──────────────────────────────────────────────
    property real gpuPercentage: 0.0

    QtObject {
        id: gpuBackend

        property var gpuProc: Process {
            command: ["bash", "-c",
            "nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits"]
            running: true
            stdout: SplitParser {
                onRead: (line) => {
                    const val = parseFloat(line.trim());
                    if (!isNaN(val))
                        root.gpuPercentage = val / 100;
                }
            }
        }

        property var gpuTimer: Timer {
            interval: 3000; repeat: true; running: true
            onTriggered: gpuBackend.gpuProc.running = true
        }
    }

    RowLayout {
        id: rowLayout
        spacing: 0
        anchors.fill: parent
        anchors.leftMargin: 4
        anchors.rightMargin: 4

        Resource {
            iconName: "memory"
            percentage: ResourceUsage.memoryUsedPercentage
            shown: true
            warningThreshold: Config.options.bar.resources.memoryWarningThreshold
        }

        Resource {
            iconName: "swap_horiz"
            percentage: ResourceUsage.swapUsedPercentage
            shown: true
            Layout.leftMargin: shown ? 6 : 0
            warningThreshold: Config.options.bar.resources.swapWarningThreshold
        }

        Resource {
            iconName: "planner_review"
            percentage: ResourceUsage.cpuUsage
            shown: true
            Layout.leftMargin: shown ? 6 : 0
            warningThreshold: Config.options.bar.resources.cpuWarningThreshold
        }

        Resource {
            iconName: "display_settings"
            percentage: root.gpuPercentage
            shown: true
            Layout.leftMargin: shown ? 6 : 0
            warningThreshold: 90
        }

        Resource {
            iconName: "hard_drive"
            percentage: root.diskPercentage
            shown: true
            Layout.leftMargin: shown ? 6 : 0
            warningThreshold: Config.options.bar.resources.diskWarningThreshold ?? 90
        }
    }

    ResourcesPopup {
        hoverTarget: root
    }
}
