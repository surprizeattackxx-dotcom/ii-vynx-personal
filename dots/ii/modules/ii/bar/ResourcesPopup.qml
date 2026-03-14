import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

StyledPopup {
    id: root

    // Fixed-size Item drives popup shell size; ColumnLayout fills it
    Item {
        id: content
        implicitWidth:  320
        implicitHeight: mainLayout.implicitHeight

        function formatKB(kb)  { return (kb / (1024 * 1024)).toFixed(1) + " GB" }
        function usageColor(r) {
            if (r < 0.60) return Appearance.colors.colSuccess;
            if (r < 0.80) return Appearance.colors.colWarning;
            return Appearance.colors.colError;
        }
        function tempColor(t) {
            if (t <= 65) return Appearance.colors.colSuccess;
            if (t <= 80) return Appearance.colors.colWarning;
            return Appearance.colors.colError;
        }

        property string cpuFreq: "…"; property string cpuTemp: "…"; property real cpuTempVal: 0
        property string diskUsed:"…"; property string diskFree:"…"; property string diskTotal:"…"; property real diskRatio: 0
        property string gpuLoad:"…"; property string gpuVramUsed:"…"; property string gpuTemp:"…"
        property real   gpuRatio: 0; property real gpuTempVal: 0; property real gpuUsage: 0

        QtObject {
            id: backend
            property var cpuFreqProc: Process {
                command: ["bash","-c","awk '/cpu MHz/{sum+=$4;n++} END{printf \"%.0f\",sum/n}' /proc/cpuinfo"]
                running: true
                stdout: SplitParser { onRead: (l) => { const v=parseFloat(l); if(!isNaN(v)) content.cpuFreq=(v/1000).toFixed(2)+" GHz"; }}
            }
            property var cpuTempProc: Process {
                command: ["bash","-c","cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0"]
                running: true
                stdout: SplitParser { onRead: (l) => { const v=parseFloat(l); if(!isNaN(v)){content.cpuTempVal=v/1000;content.cpuTemp=content.cpuTempVal.toFixed(1)+" °C";}}}
            }
            property var cpuTimer: Timer { interval:3000;repeat:true;running:true
                onTriggered:{backend.cpuFreqProc.running=true;backend.cpuTempProc.running=true;}
            }
            property var gpuProc: Process {
                command: ["bash","-c","nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.free,memory.total,temperature.gpu --format=csv,noheader,nounits"]
                running: true
                stdout: SplitParser { onRead: (l) => {
                    const p=l.trim().split(/,\s*/);
                    if(p.length>=5){
                        const load=parseFloat(p[0]),vU=parseFloat(p[1]),vF=parseFloat(p[2]),vT=parseFloat(p[3]),t=parseFloat(p[4]);
                        content.gpuUsage=load/100; content.gpuLoad=load+"%";
                        content.gpuVramUsed=(vU/1024).toFixed(1)+" GB"; content.gpuTemp=t.toFixed(1)+" °C";
                        content.gpuTempVal=t; if(vT>0) content.gpuRatio=vU/vT;
                    }
                }}
            }
            property var gpuTimer: Timer { interval:3000;repeat:true;running:true; onTriggered:backend.gpuProc.running=true }
            property var diskProc: Process {
                command: ["bash","-c","df -k / | awk 'NR==2{print $2,$3,$4}'"]
                running: true
                stdout: SplitParser { onRead: (l) => {
                    const p=l.trim().split(/\s+/);
                    if(p.length>=3){
                        const total=parseInt(p[0]),used=parseInt(p[1]),free=parseInt(p[2]);
                        if(total>0){
                            content.diskTotal=(total/(1024*1024)).toFixed(1)+" GB";
                            content.diskUsed=(used/(1024*1024)).toFixed(1)+" GB";
                            content.diskFree=(free/(1024*1024)).toFixed(1)+" GB";
                            content.diskRatio=used/total;
                        }
                    }
                }}
            }
            property var diskTimer: Timer { interval:10000;repeat:true;running:true; onTriggered:backend.diskProc.running=true }
        }

        ColumnLayout {
            id: mainLayout
            anchors.fill: parent
            spacing: 8

            StyledPopupHeaderRow {
                Layout.fillWidth: true
                icon: "memory"
                label: Translation.tr("System Resources")
            }

            component ResourceCard: Rectangle {
                property color  accent:       Appearance.colors.colPrimary
                property string resourceName: ""
                property real   ratio:        0
                property var    stats:        []

                Layout.fillWidth: true
                implicitHeight:   cardCol.implicitHeight + 14
                radius:           Appearance.rounding.small
                color:            Appearance.m3colors.m3surfaceContainerHigh
                border.width:     1
                border.color:     Qt.rgba(accent.r, accent.g, accent.b, 0.30)

                ColumnLayout {
                    id: cardCol
                    anchors { fill: parent; leftMargin: 10; rightMargin: 10; topMargin: 7; bottomMargin: 7 }
                    spacing: 5

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        Rectangle {
                            implicitWidth:  nameLabel.implicitWidth + 10
                            implicitHeight: nameLabel.implicitHeight + 4
                            radius: 4
                            color:  Qt.rgba(accent.r, accent.g, accent.b, 0.20)
                            border.width: 1
                            border.color: Qt.rgba(accent.r, accent.g, accent.b, 0.35)
                            StyledText {
                                id: nameLabel
                                anchors.centerIn: parent
                                text: resourceName
                                font { pixelSize: 10; weight: Font.Bold }
                                color: accent
                            }
                        }

                        Repeater {
                            model: stats
                            RowLayout {
                                spacing: 3
                                StyledText { text: modelData.label; font.pixelSize: 10; color: Appearance.colors.colSubtext }
                                StyledText { text: modelData.value; font.pixelSize: 10; font.weight: Font.Medium; color: modelData.color ?? Appearance.colors.colOnLayer1 }
                            }
                        }
                        Item { Layout.fillWidth: true }
                    }

                    Rectangle {
                        Layout.fillWidth: true; height: 4; radius: 2
                        color: Qt.rgba(accent.r, accent.g, accent.b, 0.15)
                        Rectangle {
                            width:  Math.max(radius*2, parent.width * Math.min(1.0, ratio))
                            height: parent.height; radius: parent.radius; color: accent
                            Behavior on width { SmoothedAnimation { velocity: 60 } }
                            Behavior on color { ColorAnimation { duration: 400 } }
                        }
                    }
                }
            }

            ResourceCard {
                accent: "#64B5F6"; resourceName: "RAM"; ratio: ResourceUsage.memoryUsedPercentage
                stats: [
                    {label:"Used",  value:content.formatKB(ResourceUsage.memoryUsed),  color:content.usageColor(ResourceUsage.memoryUsedPercentage)},
                    {label:"Free",  value:content.formatKB(ResourceUsage.memoryFree)},
                    {label:"Total", value:content.formatKB(ResourceUsage.memoryTotal),  color:Appearance.colors.colSubtext}
                ]
            }
            ResourceCard {
                visible: ResourceUsage.swapTotal > 0
                accent: "#CE93D8"; resourceName: "Swap"; ratio: ResourceUsage.swapUsedPercentage
                stats: [
                    {label:"Used",  value:content.formatKB(ResourceUsage.swapUsed),  color:content.usageColor(ResourceUsage.swapUsedPercentage)},
                    {label:"Free",  value:content.formatKB(ResourceUsage.swapFree)},
                    {label:"Total", value:content.formatKB(ResourceUsage.swapTotal),  color:Appearance.colors.colSubtext}
                ]
            }
            ResourceCard {
                accent: "#FFB74D"; resourceName: "CPU"; ratio: ResourceUsage.cpuUsage
                stats: [
                    {label:"Load", value:Math.round(ResourceUsage.cpuUsage*100)+"%", color:content.usageColor(ResourceUsage.cpuUsage)},
                    {label:"Freq", value:content.cpuFreq},
                    {label:"Temp", value:content.cpuTemp, color:content.tempColor(content.cpuTempVal)}
                ]
            }
            ResourceCard {
                accent: "#80CBC4"; resourceName: "GPU"; ratio: content.gpuUsage
                stats: [
                    {label:"Load", value:content.gpuLoad,     color:content.usageColor(content.gpuUsage)},
                    {label:"VRAM", value:content.gpuVramUsed, color:content.usageColor(content.gpuRatio)},
                    {label:"Temp", value:content.gpuTemp,     color:content.tempColor(content.gpuTempVal)}
                ]
            }
            ResourceCard {
                accent: "#81C784"; resourceName: "Disk"; ratio: content.diskRatio
                stats: [
                    {label:"Used",  value:content.diskUsed,  color:content.usageColor(content.diskRatio)},
                    {label:"Free",  value:content.diskFree},
                    {label:"Total", value:content.diskTotal,  color:Appearance.colors.colSubtext}
                ]
            }
        }
    }
}
