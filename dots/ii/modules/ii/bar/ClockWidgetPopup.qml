import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

StyledPopup {
    id: root
    property string formattedDate:   Qt.locale().toString(DateTime.clock.date, "dddd, MMMM dd, yyyy")
    property string formattedTime:   DateTime.time
    property string formattedUptime: DateTime.uptime
    property string todosSection:    getUpcomingTodos()

    function getUpcomingTodos() {
        const unfinished = Todo.list.filter(i => !i.done);
        if (unfinished.length === 0) return Translation.tr("No pending tasks");
        let t = unfinished.slice(0, 5).map((i, n) => `  ${n + 1}. ${i.content}`).join('\n');
        if (unfinished.length > 5)
            t += `\n  ${Translation.tr("... and %1 more").arg(unfinished.length - 5)}`;
        return t;
    }

    // Fixed-width column — drives popup size, never reads parent.width
    ColumnLayout {
        anchors.centerIn: parent
        spacing: 8

        StyledPopupHeaderRow {
            Layout.fillWidth: true
            icon:  "calendar_month"
            label: root.formattedDate
        }

        // Divider
        Rectangle {
            Layout.fillWidth: true; height: 1
            color: Qt.rgba(Appearance.colors.colPrimary.r,
                           Appearance.colors.colPrimary.g,
                           Appearance.colors.colPrimary.b, 0.15)
        }

        StyledPopupValueRow {
            Layout.fillWidth: true
            icon:  "timelapse"
            label: Translation.tr("System uptime:")
            value: root.formattedUptime
        }

        Rectangle {
            Layout.fillWidth: true; height: 1
            color: Qt.rgba(Appearance.colors.colPrimary.r,
                           Appearance.colors.colPrimary.g,
                           Appearance.colors.colPrimary.b, 0.10)
        }

        // To-do section
        Column {
            Layout.fillWidth: true
            spacing: 6

            StyledPopupValueRow {
                width: parent.width
                icon:  "checklist"
                label: Translation.tr("To Do:")
                value: ""
            }

            Rectangle {
                width:          parent.width
                implicitHeight: todoText.implicitHeight + 16
                radius:         Appearance.rounding.small
                // M3 surfaceContainerHigh — elevated card feel
                color:          Appearance.m3colors.m3surfaceContainerHigh
                border.width:   1
                border.color:   Qt.rgba(Appearance.colors.colPrimary.r,
                                        Appearance.colors.colPrimary.g,
                                        Appearance.colors.colPrimary.b, 0.18)

                StyledText {
                    id: todoText
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8 }
                    horizontalAlignment: Text.AlignLeft
                    wrapMode:  Text.Wrap
                    color:     Appearance.colors.colOnSurfaceVariant
                    font.pixelSize: Appearance.font.pixelSize.small
                    text:      root.todosSection
                }
            }
        }
    }
}
