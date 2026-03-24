import QtQuick
import QtQuick.Layouts
import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.services
import "calendar_layout.js" as CalendarLayout

Item {
    id: root

    property int monthShift: 0
    property date viewingDate
    property var calendarLayout
    property date selectedDate

    // Drag state from parent
    property var draggingEvent: null
    property bool isDragging: false

    signal dateSelected(date date)
    signal eventDropped(var eventData, date targetDate)
    signal quickCreateRequested(date cellDate)

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 4

        // Weekday headers
        RowLayout {
            Layout.fillWidth: true
            spacing: 4

            Repeater {
                model: CalendarLayout.weekDays.map((_, i) => {
                    return CalendarLayout.weekDays[(i + Config.options.time.firstDayOfWeek) % 7];
                })

                delegate: Item {
                    Layout.fillWidth: true
                    implicitHeight: 32

                    StyledText {
                        anchors.centerIn: parent
                        text: Translation.tr(modelData.day)
                        font.weight: Font.DemiBold
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: Appearance.m3colors.m3onSurfaceVariant
                    }
                }
            }
        }

        // Calendar grid — 6 rows × 7 columns
        Repeater {
            model: 6

            delegate: RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 4

                Repeater {
                    // Pass outer row index via Array.fill so inner delegate gets it as modelData
                    model: Array(7).fill(modelData)

                    delegate: MonthDayCell {
                        Layout.fillWidth: true
                        Layout.fillHeight: true

                        property var cellData: root.calendarLayout[modelData]
                            ? root.calendarLayout[modelData][index]
                            : null

                        day: cellData ? cellData.day : 0
                        isToday: cellData ? cellData.today : -1
                        cellDate: cellData ? new Date(cellData.year, cellData.month, cellData.day) : new Date()
                        isSelected: cellData ? (
                            cellData.day === root.selectedDate.getDate() &&
                            cellData.month === root.selectedDate.getMonth() &&
                            cellData.year === root.selectedDate.getFullYear() &&
                            cellData.today !== -1
                        ) : false
                        taskList: cellData ? CalendarService.getFilteredTasksByDate(
                            new Date(cellData.year, cellData.month, cellData.day)
                        ) : []
                        dropHighlight: root.isDragging && hoverHandler.hovered

                        HoverHandler {
                            id: hoverHandler
                        }

                        // Handle drop — only created when dragging
                        Loader {
                            anchors.fill: parent
                            active: root.isDragging
                            z: 20
                            sourceComponent: MouseArea {
                                anchors.fill: parent
                                onReleased: {
                                    if (root.isDragging && root.draggingEvent && cellData) {
                                        root.eventDropped(root.draggingEvent,
                                            new Date(cellData.year, cellData.month, cellData.day));
                                    }
                                }
                            }
                        }

                        onCellClicked: (date) => root.dateSelected(date)
                    }
                }
            }
        }
    }
}
