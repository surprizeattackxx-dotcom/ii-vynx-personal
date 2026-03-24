import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.services

WindowDialog {
    id: root

    property bool editMode: false
    property date selectedDate: new Date()

    // Edit mode pre-fill data
    property string existingEventId: ""
    property string existingCalendarId: ""
    property string existingAccountName: ""
    property string existingTitle: ""
    property string existingDescription: ""
    property date existingStartDate: new Date()
    property date existingEndDate: new Date()
    property var existingRecurrence: []

    readonly property var recurrenceOptions: [
        Translation.tr("Does not repeat"),
        Translation.tr("Daily"),
        Translation.tr("Weekly"),
        Translation.tr("Monthly"),
        Translation.tr("Yearly")
    ]
    readonly property var recurrenceRules: [
        "",
        "RRULE:FREQ=DAILY",
        "RRULE:FREQ=WEEKLY",
        "RRULE:FREQ=MONTHLY",
        "RRULE:FREQ=YEARLY"
    ]

    // 12-hour time helpers
    readonly property var hourModel: ["12", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11"]
    readonly property var minuteModel: ["00", "05", "10", "15", "20", "25", "30", "35", "40", "45", "50", "55"]

    function hour24ToCombo(h24) {
        // Returns {hourIndex, ampmIndex} for the combo boxes
        const ampm = h24 >= 12 ? 1 : 0;
        const h12 = h24 % 12; // 0=12, 1=1, ..., 11=11
        return { hourIndex: h12, ampmIndex: ampm };
    }

    function minuteToCombo(m) {
        // Snap to nearest 5-minute interval
        return Math.round(m / 5) % 12;
    }

    function comboToHour24(hourIndex, ampmIndex) {
        // hourIndex: 0=12, 1=1, ..., 11=11; ampmIndex: 0=AM, 1=PM
        let h = hourIndex; // 0 means 12 o'clock
        if (ampmIndex === 1) h += 12; // PM
        if (hourIndex === 0 && ampmIndex === 0) h = 0; // 12 AM = 0
        return h;
    }

    function comboToMinute(minIndex) {
        return minIndex * 5;
    }

    backgroundWidth: 400
    backgroundHeight: 620

    onShowChanged: {
        if (show) {
            titleField.text = editMode ? existingTitle : "";
            descriptionField.text = editMode ? existingDescription : "";
            allDaySwitch.checked = false;

            if (editMode) {
                const sh = hour24ToCombo(existingStartDate.getHours());
                startHourCombo.currentIndex = sh.hourIndex;
                startAmPmCombo.currentIndex = sh.ampmIndex;
                startMinCombo.currentIndex = minuteToCombo(existingStartDate.getMinutes());

                const eh = hour24ToCombo(existingEndDate.getHours());
                endHourCombo.currentIndex = eh.hourIndex;
                endAmPmCombo.currentIndex = eh.ampmIndex;
                endMinCombo.currentIndex = minuteToCombo(existingEndDate.getMinutes());
            } else {
                // Default: next full hour, 1 hour duration
                const now = new Date();
                const startH = (now.getHours() + 1) % 24;
                const endH = (now.getHours() + 2) % 24;

                const sh = hour24ToCombo(startH);
                startHourCombo.currentIndex = sh.hourIndex;
                startAmPmCombo.currentIndex = sh.ampmIndex;
                startMinCombo.currentIndex = 0;

                const eh = hour24ToCombo(endH);
                endHourCombo.currentIndex = eh.hourIndex;
                endAmPmCombo.currentIndex = eh.ampmIndex;
                endMinCombo.currentIndex = 0;
            }

            // Pre-select recurrence
            if (editMode && existingRecurrence.length > 0) {
                const rule = existingRecurrence[0];
                let idx = 0;
                if (rule.includes("DAILY")) idx = 1;
                else if (rule.includes("WEEKLY")) idx = 2;
                else if (rule.includes("MONTHLY")) idx = 3;
                else if (rule.includes("YEARLY")) idx = 4;
                recurrenceCombo.currentIndex = idx;
            } else {
                recurrenceCombo.currentIndex = 0;
            }

            // Pre-select calendar
            if (editMode && existingCalendarId) {
                for (let i = 0; i < CalendarService.calendarList.length; i++) {
                    if (CalendarService.calendarList[i].calendarId === existingCalendarId) {
                        calendarCombo.currentIndex = i;
                        break;
                    }
                }
            } else if (CalendarService.calendarList.length > 0) {
                calendarCombo.currentIndex = 0;
            }

            titleField.forceActiveFocus();
        }
    }

    // Title
    WindowDialogTitle {
        text: root.editMode ? Translation.tr("Edit Event") : Translation.tr("New Event")
    }

    // Event title input
    MaterialTextField {
        id: titleField
        Layout.fillWidth: true
        placeholderText: Translation.tr("Event title")
    }

    // Description input
    MaterialTextArea {
        id: descriptionField
        Layout.fillWidth: true
        Layout.preferredHeight: 80
        placeholderText: Translation.tr("Description (optional)")
    }

    // All-day toggle
    RowLayout {
        Layout.fillWidth: true
        spacing: 12

        MaterialSymbol {
            text: "schedule"
            iconSize: 20
            color: Appearance.m3colors.m3onSurfaceVariant
        }

        StyledText {
            text: Translation.tr("All day")
            color: Appearance.m3colors.m3onSurface
            Layout.fillWidth: true
        }

        StyledSwitch {
            id: allDaySwitch
        }
    }

    // Date display
    RowLayout {
        Layout.fillWidth: true
        spacing: 12

        MaterialSymbol {
            text: "calendar_today"
            iconSize: 20
            color: Appearance.m3colors.m3onSurfaceVariant
        }

        StyledText {
            text: root.selectedDate.toLocaleDateString(Qt.locale(), "dddd, MMMM d, yyyy")
            color: Appearance.m3colors.m3onSurface
            font.weight: Font.DemiBold
        }
    }

    // Start time (hidden when all-day)
    RowLayout {
        Layout.fillWidth: true
        spacing: 6
        visible: !allDaySwitch.checked

        MaterialSymbol {
            text: "schedule"
            iconSize: 20
            color: Appearance.m3colors.m3onSurfaceVariant
        }

        StyledText {
            text: Translation.tr("Start")
            color: Appearance.m3colors.m3onSurfaceVariant
            Layout.preferredWidth: 36
        }

        StyledComboBox {
            id: startHourCombo
            model: root.hourModel
            Layout.preferredWidth: 62
        }

        StyledText {
            text: ":"
            color: Appearance.m3colors.m3onSurface
            font.weight: Font.Bold
        }

        StyledComboBox {
            id: startMinCombo
            model: root.minuteModel
            Layout.preferredWidth: 62
        }

        StyledComboBox {
            id: startAmPmCombo
            model: ["AM", "PM"]
            Layout.preferredWidth: 68
        }

        Item { Layout.fillWidth: true }
    }

    // End time (hidden when all-day)
    RowLayout {
        Layout.fillWidth: true
        spacing: 6
        visible: !allDaySwitch.checked

        MaterialSymbol {
            text: "schedule"
            iconSize: 20
            color: Appearance.m3colors.m3onSurfaceVariant
            opacity: 0
        }

        StyledText {
            text: Translation.tr("End")
            color: Appearance.m3colors.m3onSurfaceVariant
            Layout.preferredWidth: 36
        }

        StyledComboBox {
            id: endHourCombo
            model: root.hourModel
            Layout.preferredWidth: 62
        }

        StyledText {
            text: ":"
            color: Appearance.m3colors.m3onSurface
            font.weight: Font.Bold
        }

        StyledComboBox {
            id: endMinCombo
            model: root.minuteModel
            Layout.preferredWidth: 62
        }

        StyledComboBox {
            id: endAmPmCombo
            model: ["AM", "PM"]
            Layout.preferredWidth: 68
        }

        Item { Layout.fillWidth: true }
    }

    // Calendar selector
    RowLayout {
        Layout.fillWidth: true
        spacing: 12

        MaterialSymbol {
            text: "event_note"
            iconSize: 20
            color: Appearance.m3colors.m3onSurfaceVariant
        }

        StyledComboBox {
            id: calendarCombo
            Layout.fillWidth: true
            model: CalendarService.calendarList.map(c => c.calendarSummary)
        }
    }

    // Recurrence selector
    RowLayout {
        Layout.fillWidth: true
        spacing: 12

        MaterialSymbol {
            text: "repeat"
            iconSize: 20
            color: Appearance.m3colors.m3onSurfaceVariant
        }

        StyledComboBox {
            id: recurrenceCombo
            Layout.fillWidth: true
            model: root.recurrenceOptions
        }
    }

    // Spacer
    Item { Layout.fillHeight: true }

    // Buttons
    WindowDialogButtonRow {
        Item { Layout.fillWidth: true }

        DialogButton {
            buttonText: Translation.tr("Cancel")
            downAction: () => root.dismiss()
        }

        DialogButton {
            buttonText: root.editMode ? Translation.tr("Save") : Translation.tr("Create")
            enabled: titleField.text.trim().length > 0 && !CalendarService.mutating
            colEnabled: Appearance.m3colors.m3primary
            downAction: () => {
                const calIdx = calendarCombo.currentIndex;
                if (calIdx < 0 || calIdx >= CalendarService.calendarList.length) return;

                const cal = CalendarService.calendarList[calIdx];
                const title = titleField.text.trim();
                const desc = descriptionField.text.trim();
                const isAllDay = allDaySwitch.checked;

                const startH24 = root.comboToHour24(startHourCombo.currentIndex, startAmPmCombo.currentIndex);
                const startMin = root.comboToMinute(startMinCombo.currentIndex);
                const endH24 = root.comboToHour24(endHourCombo.currentIndex, endAmPmCombo.currentIndex);
                const endMin = root.comboToMinute(endMinCombo.currentIndex);

                const startDate = new Date(
                    root.selectedDate.getFullYear(),
                    root.selectedDate.getMonth(),
                    root.selectedDate.getDate(),
                    startH24, startMin
                );
                const endDate = new Date(
                    root.selectedDate.getFullYear(),
                    root.selectedDate.getMonth(),
                    root.selectedDate.getDate(),
                    endH24, endMin
                );

                // Build recurrence array
                const rruleIdx = recurrenceCombo.currentIndex;
                const recurrence = rruleIdx > 0 ? [root.recurrenceRules[rruleIdx]] : [];

                if (root.editMode) {
                    CalendarService.updateEvent(
                        cal.calendarId, cal.accountName,
                        root.existingEventId,
                        title, desc, startDate, endDate, isAllDay, recurrence
                    );
                } else {
                    CalendarService.createEvent(
                        cal.calendarId, cal.accountName,
                        title, desc, startDate, endDate, isAllDay, recurrence
                    );
                }

                root.dismiss();
            }
        }
    }
}
