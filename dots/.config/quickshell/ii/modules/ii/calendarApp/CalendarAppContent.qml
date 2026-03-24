import QtQuick
import QtQuick.Layouts
import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.services
import "calendar_layout.js" as CalendarLayout

Rectangle {
    id: root
    signal closeRequested()

    color: Appearance.m3colors.m3surface
    radius: Appearance.rounding.normal + 8
    border.width: 1
    border.color: Appearance.m3colors.m3outlineVariant

    clip: true

    // State
    property int monthShift: 0
    property date selectedDate: new Date()
    property date viewingDate: CalendarLayout.getDateInXMonthsTime(monthShift)
    property var calendarLayout: CalendarLayout.getCalendarLayout(viewingDate, monthShift === 0, Config.options.time.firstDayOfWeek)
    property int currentView: 0 // 0 = month, 1 = agenda

    // Dialog state
    property bool showEventForm: false
    property bool showDeleteConfirm: false
    property var editingEvent: null   // null = create mode, object = edit mode
    property var deletingEvent: null

    // Search state
    property bool searchMode: false
    property string searchQuery: ""

    // Drag state
    property var draggingEvent: null
    property bool isDragging: false

    // Shadow/elevation effect
    layer.enabled: true
    layer.effect: null

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 0
        spacing: 0

        // Navigation bar
        CalendarNavBar {
            Layout.fillWidth: true
            monthShift: root.monthShift
            viewingDate: root.viewingDate
            currentView: root.currentView
            searchMode: root.searchMode

            onPreviousMonth: root.monthShift--
            onNextMonth: root.monthShift++
            onGoToToday: {
                root.monthShift = 0;
                root.selectedDate = new Date();
            }
            onViewChanged: (view) => root.currentView = view
            onClose: root.closeRequested()
            onSearchQueryUpdated: (query) => root.searchQuery = query
            onSearchModeToggled: (active) => root.searchMode = active
        }

        // Separator
        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: Appearance.m3colors.m3outlineVariant
        }

        // Main content area
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            // Month view
            RowLayout {
                anchors.fill: parent
                spacing: 0
                visible: root.currentView === 0 && !root.searchMode

                // Month grid (left side)
                MonthView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.preferredWidth: 3
                    monthShift: root.monthShift
                    viewingDate: root.viewingDate
                    calendarLayout: root.calendarLayout
                    selectedDate: root.selectedDate
                    draggingEvent: root.draggingEvent
                    isDragging: root.isDragging
                    onDateSelected: (date) => root.selectedDate = date
                    onMonthShiftChanged: (delta) => root.monthShift += delta
                    onEventDropped: (eventData, targetDate) => {
                        root.isDragging = false;
                        root.draggingEvent = null;
                        CalendarService.moveEvent(eventData, targetDate);
                    }
                }

                // Vertical separator
                Rectangle {
                    Layout.fillHeight: true
                    width: 1
                    color: Appearance.m3colors.m3outlineVariant
                }

                // Day detail panel (right side)
                DayDetailPanel {
                    Layout.fillHeight: true
                    Layout.preferredWidth: 260
                    Layout.minimumWidth: 240
                    selectedDate: root.selectedDate

                    onCreateEventRequested: {
                        root.editingEvent = null;
                        root.showEventForm = true;
                    }
                    onEditEventRequested: (eventData) => {
                        root.editingEvent = eventData;
                        root.showEventForm = true;
                    }
                    onDeleteEventRequested: (eventData) => {
                        root.deletingEvent = eventData;
                        root.showDeleteConfirm = true;
                    }
                    onDragStarted: (eventData) => {
                        root.draggingEvent = eventData;
                        root.isDragging = true;
                    }
                }
            }

            // Agenda view
            AgendaView {
                anchors.fill: parent
                anchors.margins: 16
                visible: root.currentView === 1 && !root.searchMode
            }

            // Week view
            WeekView {
                anchors.fill: parent
                visible: root.currentView === 2 && !root.searchMode
                selectedDate: root.selectedDate
                onDateSelected: (date) => root.selectedDate = date
                onCreateEventRequested: (date, hour) => {
                    root.selectedDate = date;
                    root.editingEvent = null;
                    root.showEventForm = true;
                }
                onEditEventRequested: (eventData) => {
                    root.editingEvent = eventData;
                    root.showEventForm = true;
                }
                onDeleteEventRequested: (eventData) => {
                    root.deletingEvent = eventData;
                    root.showDeleteConfirm = true;
                }
            }

            // Search results overlay
            SearchResultsOverlay {
                anchors.fill: parent
                anchors.margins: 16
                visible: root.searchMode
                searchQuery: root.searchQuery
                onEventClicked: (eventData) => {
                    root.selectedDate = eventData.startDate;
                    root.monthShift = (eventData.startDate.getFullYear() - new Date().getFullYear()) * 12
                                    + eventData.startDate.getMonth() - new Date().getMonth();
                    root.searchMode = false;
                    root.searchQuery = "";
                }
            }
        }
    }

    // --- Event Form Dialog (create/edit) ---
    Loader {
        anchors.fill: parent
        active: root.showEventForm
        z: 100

        sourceComponent: EventFormDialog {
            anchors.fill: parent
            show: root.showEventForm
            editMode: root.editingEvent !== null
            selectedDate: root.selectedDate

            // Pre-fill for edit mode
            existingEventId: root.editingEvent?.eventId ?? ""
            existingCalendarId: root.editingEvent?.calendarId ?? ""
            existingAccountName: root.editingEvent?.accountName ?? ""
            existingTitle: root.editingEvent?.content ?? ""
            existingDescription: root.editingEvent?.description ?? ""
            existingStartDate: root.editingEvent?.startDate ?? new Date()
            existingEndDate: root.editingEvent?.endDate ?? new Date()
            existingRecurrence: root.editingEvent?.recurrence ?? []

            onDismiss: {
                root.showEventForm = false;
                root.editingEvent = null;
            }
        }
    }

    // --- Delete Confirm Dialog ---
    Loader {
        anchors.fill: parent
        active: root.showDeleteConfirm
        z: 100

        sourceComponent: DeleteConfirmDialog {
            anchors.fill: parent
            show: root.showDeleteConfirm
            eventTitle: root.deletingEvent?.content ?? ""
            eventId: root.deletingEvent?.eventId ?? ""
            calendarId: root.deletingEvent?.calendarId ?? ""
            accountName: root.deletingEvent?.accountName ?? ""

            onDismiss: {
                root.showDeleteConfirm = false;
                root.deletingEvent = null;
            }
        }
    }

    // Keyboard navigation
    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_PageDown) {
            root.monthShift++;
            event.accepted = true;
        } else if (event.key === Qt.Key_PageUp) {
            root.monthShift--;
            event.accepted = true;
        } else if (event.key === Qt.Key_Home) {
            root.monthShift = 0;
            root.selectedDate = new Date();
            event.accepted = true;
        } else if (event.key === Qt.Key_Left) {
            // Move selected date back 1 day
            let d = new Date(root.selectedDate);
            d.setDate(d.getDate() - 1);
            root.selectedDate = d;
            root.monthShift = (d.getFullYear() - new Date().getFullYear()) * 12 + d.getMonth() - new Date().getMonth();
            event.accepted = true;
        } else if (event.key === Qt.Key_Right) {
            let d = new Date(root.selectedDate);
            d.setDate(d.getDate() + 1);
            root.selectedDate = d;
            root.monthShift = (d.getFullYear() - new Date().getFullYear()) * 12 + d.getMonth() - new Date().getMonth();
            event.accepted = true;
        } else if (event.key === Qt.Key_Up) {
            let d = new Date(root.selectedDate);
            d.setDate(d.getDate() - 7);
            root.selectedDate = d;
            root.monthShift = (d.getFullYear() - new Date().getFullYear()) * 12 + d.getMonth() - new Date().getMonth();
            event.accepted = true;
        } else if (event.key === Qt.Key_Down) {
            let d = new Date(root.selectedDate);
            d.setDate(d.getDate() + 7);
            root.selectedDate = d;
            root.monthShift = (d.getFullYear() - new Date().getFullYear()) * 12 + d.getMonth() - new Date().getMonth();
            event.accepted = true;
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            // Create event on selected date
            root.editingEvent = null;
            root.showEventForm = true;
            event.accepted = true;
        } else if (event.key === Qt.Key_E) {
            // Edit first gcal event on selected date
            const events = CalendarService.getFilteredTasksByDate(root.selectedDate);
            const gcalEvt = events.find(e => e.source === "gcal" && e.eventId);
            if (gcalEvt) {
                root.editingEvent = gcalEvt;
                root.showEventForm = true;
            }
            event.accepted = true;
        } else if (event.key === Qt.Key_D) {
            // Delete first gcal event on selected date
            const events = CalendarService.getFilteredTasksByDate(root.selectedDate);
            const gcalEvt = events.find(e => e.source === "gcal" && e.eventId);
            if (gcalEvt) {
                root.deletingEvent = gcalEvt;
                root.showDeleteConfirm = true;
            }
            event.accepted = true;
        } else if (event.key === Qt.Key_1) {
            root.currentView = 0;
            event.accepted = true;
        } else if (event.key === Qt.Key_2) {
            root.currentView = 1;
            event.accepted = true;
        } else if (event.key === Qt.Key_3) {
            root.currentView = 2;
            event.accepted = true;
        } else if (event.key === Qt.Key_F && (event.modifiers & Qt.ControlModifier)) {
            root.searchMode = !root.searchMode;
            event.accepted = true;
        }
    }

    WheelHandler {
        onWheel: (event) => {
            if (event.angleDelta.y > 0)
                root.monthShift--;
            else if (event.angleDelta.y < 0)
                root.monthShift++;
        }
    }
}
