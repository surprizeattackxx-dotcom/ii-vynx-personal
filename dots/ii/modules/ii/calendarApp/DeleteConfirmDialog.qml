import QtQuick
import QtQuick.Layouts
import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.services

WindowDialog {
    id: root

    property string eventTitle: ""
    property string eventId: ""
    property string calendarId: ""
    property string accountName: ""

    backgroundWidth: 360
    backgroundHeight: 200

    WindowDialogTitle {
        text: Translation.tr("Delete event?")
    }

    WindowDialogParagraph {
        text: Translation.tr("Are you sure you want to delete") + " \"" + root.eventTitle + "\"?"
    }

    Item { Layout.fillHeight: true }

    WindowDialogButtonRow {
        Item { Layout.fillWidth: true }

        DialogButton {
            buttonText: Translation.tr("Cancel")
            downAction: () => root.dismiss()
        }

        DialogButton {
            buttonText: Translation.tr("Delete")
            enabled: !CalendarService.mutating
            colEnabled: Appearance.m3colors.m3error
            downAction: () => {
                CalendarService.deleteEvent(root.calendarId, root.accountName, root.eventId);
                root.dismiss();
            }
        }
    }
}
