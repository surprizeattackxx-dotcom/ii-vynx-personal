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

    readonly property var todayEvents: CalendarService.khalAvailable
        ? CalendarService.getTasksByDate(new Date()) : []
    readonly property var tomorrowEvents: {
        if (!CalendarService.khalAvailable) return []
        const d = new Date(); d.setDate(d.getDate() + 1)
        return CalendarService.getTasksByDate(d)
    }

    function getUpcomingTodos() {
        const showDueDates = Config.options.todo?.showDueDates ?? true
        const now = Date.now()
        const unfinished = Todo.list.filter(i => !i.done);
        if (unfinished.length === 0) return Translation.tr("No pending tasks");
        let t = unfinished.slice(0, 5).map((i, n) => {
            let prefix = `  ${n + 1}. ${i.content}`
            if (showDueDates && i.dueDate !== undefined && i.dueDate !== null) {
                const overdue = i.dueDate < now
                const dateStr = Qt.formatDateTime(new Date(i.dueDate), "MMM dd")
                prefix += overdue ? ` ⚠ ${dateStr}` : ` · ${dateStr}`
            }
            return prefix
        }).join('\n');
        if (unfinished.length > 5)
            t += `\n  ${Translation.tr("... and %1 more").arg(unfinished.length - 5)}`;
        return t;
    }

    function formatEventTime(event) {
        const start = Qt.formatDateTime(event.startDate, Config.options.time.format)
        const end   = Qt.formatDateTime(event.endDate,   Config.options.time.format)
        return start + " – " + end
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

        // Calendar events section — only shown when khal is available
        Loader {
            active: CalendarService.khalAvailable
            visible: active
            Layout.fillWidth: true
            sourceComponent: Column {
                spacing: 6

                Rectangle {
                    width: parent.width; height: 1
                    color: Qt.rgba(Appearance.colors.colPrimary.r,
                                   Appearance.colors.colPrimary.g,
                                   Appearance.colors.colPrimary.b, 0.10)
                }

                // Today's events
                StyledPopupValueRow {
                    width: parent.width
                    icon:  "event"
                    label: Translation.tr("Today:")
                    value: root.todayEvents.length === 0 ? Translation.tr("No events") : ""
                }

                Repeater {
                    model: root.todayEvents.slice(0, 5)
                    delegate: Rectangle {
                        required property var modelData
                        width: parent.width
                        implicitHeight: eventCol.implicitHeight + 12
                        radius: Appearance.rounding.small
                        color: Appearance.m3colors.m3surfaceContainerHigh
                        border.width: 1
                        border.color: Qt.rgba(modelData.color.r,
                                              modelData.color.g,
                                              modelData.color.b, 0.40)

                        Column {
                            id: eventCol
                            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8 }
                            spacing: 2

                            RowLayout {
                                width: parent.width
                                spacing: 6
                                Rectangle {
                                    width: 8; height: 8; radius: 4
                                    color: modelData.color
                                    Layout.alignment: Qt.AlignVCenter
                                }
                                StyledText {
                                    Layout.fillWidth: true
                                    text: modelData.content
                                    font.pixelSize: Appearance.font.pixelSize.small
                                    color: Appearance.colors.colOnLayer1
                                    elide: Text.ElideRight
                                }
                            }
                            StyledText {
                                text: root.formatEventTime(modelData)
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: Appearance.m3colors.m3outline
                            }
                        }
                    }
                }

                // Tomorrow's events — only if there are any
                Loader {
                    active: root.tomorrowEvents.length > 0
                    visible: active
                    width: parent.width
                    sourceComponent: Column {
                        spacing: 6

                        StyledPopupValueRow {
                            width: parent.width
                            icon:  "event_upcoming"
                            label: Translation.tr("Tomorrow:")
                            value: ""
                        }

                        Repeater {
                            model: root.tomorrowEvents.slice(0, 3)
                            delegate: Rectangle {
                                required property var modelData
                                width: parent.width
                                implicitHeight: tomorrowEventCol.implicitHeight + 12
                                radius: Appearance.rounding.small
                                color: Appearance.m3colors.m3surfaceContainerHigh
                                border.width: 1
                                border.color: Qt.rgba(modelData.color.r,
                                                      modelData.color.g,
                                                      modelData.color.b, 0.40)

                                Column {
                                    id: tomorrowEventCol
                                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8 }
                                    spacing: 2

                                    RowLayout {
                                        width: parent.width
                                        spacing: 6
                                        Rectangle {
                                            width: 8; height: 8; radius: 4
                                            color: modelData.color
                                            Layout.alignment: Qt.AlignVCenter
                                        }
                                        StyledText {
                                            Layout.fillWidth: true
                                            text: modelData.content
                                            font.pixelSize: Appearance.font.pixelSize.small
                                            color: Appearance.colors.colOnLayer1
                                            elide: Text.ElideRight
                                        }
                                    }
                                    StyledText {
                                        text: root.formatEventTime(modelData)
                                        font.pixelSize: Appearance.font.pixelSize.smaller
                                        color: Appearance.m3colors.m3outline
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
