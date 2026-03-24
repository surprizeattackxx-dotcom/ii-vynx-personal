import QtQuick
import QtQuick.Layouts
import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.services

Rectangle {
    id: root
    implicitHeight: 56
    color: Appearance.m3colors.m3surfaceContainer
    radius: Appearance.rounding.normal + 8

    // Flatten bottom corners to join with content
    Rectangle {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: parent.radius
        color: parent.color
    }

    property int monthShift: 0
    property date viewingDate
    property int currentView: 0
    property bool searchMode: false
    property string searchQuery: ""
    property bool showFilter: false

    signal previousMonth()
    signal nextMonth()
    signal goToToday()
    signal viewChanged(int view)
    signal close()
    signal searchQueryUpdated(string query)
    signal searchModeToggled(bool active)

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 16
        anchors.rightMargin: 12
        spacing: 8

        // Calendar icon
        MaterialSymbol {
            text: "calendar_month"
            iconSize: 24
            color: Appearance.m3colors.m3primary
        }

        // Month/Year label
        StyledText {
            text: viewingDate.toLocaleDateString(Qt.locale(), "MMMM yyyy")
            font.pixelSize: Appearance.font.pixelSize.larger + 2
            font.weight: Font.DemiBold
            color: Appearance.m3colors.m3onSurface
        }

        // Dot indicator if not on current month
        Rectangle {
            width: 6
            height: 6
            radius: 3
            color: Appearance.m3colors.m3primary
            visible: root.monthShift !== 0
        }

        Item { Layout.fillWidth: true }

        // Navigation buttons
        RippleButton {
            implicitWidth: 36
            implicitHeight: 36
            buttonRadius: Appearance.rounding.full
            downAction: () => root.previousMonth()

            contentItem: MaterialSymbol {
                text: "chevron_left"
                iconSize: 20
                horizontalAlignment: Text.AlignHCenter
                color: Appearance.m3colors.m3onSurfaceVariant
            }
        }

        RippleButton {
            implicitWidth: 36
            implicitHeight: 36
            buttonRadius: Appearance.rounding.full
            downAction: () => root.nextMonth()

            contentItem: MaterialSymbol {
                text: "chevron_right"
                iconSize: 20
                horizontalAlignment: Text.AlignHCenter
                color: Appearance.m3colors.m3onSurfaceVariant
            }
        }

        // Spacer
        Rectangle { width: 1; height: 24; color: Appearance.m3colors.m3outlineVariant }

        // View toggle: Month
        RippleButton {
            implicitWidth: 36
            implicitHeight: 36
            buttonRadius: Appearance.rounding.full
            toggled: root.currentView === 0
            downAction: () => root.viewChanged(0)

            contentItem: MaterialSymbol {
                text: "calendar_view_month"
                iconSize: 20
                horizontalAlignment: Text.AlignHCenter
                color: root.currentView === 0 ? Appearance.m3colors.m3onPrimary : Appearance.m3colors.m3onSurfaceVariant
            }

            StyledToolTip {
                text: Translation.tr("Month view")
            }
        }

        // View toggle: Week
        RippleButton {
            implicitWidth: 36
            implicitHeight: 36
            buttonRadius: Appearance.rounding.full
            toggled: root.currentView === 2
            downAction: () => root.viewChanged(2)

            contentItem: MaterialSymbol {
                text: "calendar_view_week"
                iconSize: 20
                horizontalAlignment: Text.AlignHCenter
                color: root.currentView === 2 ? Appearance.m3colors.m3onPrimary : Appearance.m3colors.m3onSurfaceVariant
            }

            StyledToolTip {
                text: Translation.tr("Week view")
            }
        }

        // View toggle: Agenda
        RippleButton {
            implicitWidth: 36
            implicitHeight: 36
            buttonRadius: Appearance.rounding.full
            toggled: root.currentView === 1
            downAction: () => root.viewChanged(1)

            contentItem: MaterialSymbol {
                text: "view_agenda"
                iconSize: 20
                horizontalAlignment: Text.AlignHCenter
                color: root.currentView === 1 ? Appearance.m3colors.m3onPrimary : Appearance.m3colors.m3onSurfaceVariant
            }

            StyledToolTip {
                text: Translation.tr("Agenda view")
            }
        }

        // Spacer
        Rectangle { width: 1; height: 24; color: Appearance.m3colors.m3outlineVariant }

        // Filter button
        RippleButton {
            id: filterBtn
            implicitWidth: 36
            implicitHeight: 36
            buttonRadius: Appearance.rounding.full
            toggled: root.showFilter
            downAction: () => root.showFilter = !root.showFilter

            contentItem: MaterialSymbol {
                text: "filter_list"
                iconSize: 20
                horizontalAlignment: Text.AlignHCenter
                color: root.showFilter ? Appearance.m3colors.m3onPrimary : Appearance.m3colors.m3onSurfaceVariant
            }

            StyledToolTip {
                text: Translation.tr("Filter calendars")
            }

            CalendarFilterPopup {
                show: root.showFilter
                anchors.top: parent.bottom
                anchors.topMargin: 8
                anchors.right: parent.right
            }
        }

        // Search button / search field
        RippleButton {
            implicitWidth: 36
            implicitHeight: 36
            buttonRadius: Appearance.rounding.full
            visible: !root.searchMode
            downAction: () => {
                root.searchMode = true;
                root.searchModeToggled(true);
            }

            contentItem: MaterialSymbol {
                text: "search"
                iconSize: 20
                horizontalAlignment: Text.AlignHCenter
                color: Appearance.m3colors.m3onSurfaceVariant
            }

            StyledToolTip {
                text: Translation.tr("Search events")
            }
        }

        // Inline search field (visible when search mode active)
        RowLayout {
            visible: root.searchMode
            spacing: 4

            MaterialTextField {
                id: searchField
                Layout.preferredWidth: 180
                Layout.preferredHeight: 36
                placeholderText: Translation.tr("Search events...")
                font.pixelSize: Appearance.font.pixelSize.small

                Component.onCompleted: if (root.searchMode) forceActiveFocus()
                onTextChanged: root.searchQueryUpdated(text)

                Keys.onEscapePressed: {
                    root.searchMode = false;
                    root.searchModeToggled(false);
                    root.searchQueryUpdated("");
                    text = "";
                }
            }

            RippleButton {
                implicitWidth: 28
                implicitHeight: 28
                buttonRadius: Appearance.rounding.full
                downAction: () => {
                    root.searchMode = false;
                    root.searchModeToggled(false);
                    root.searchQueryUpdated("");
                    searchField.text = "";
                }

                contentItem: MaterialSymbol {
                    text: "close"
                    iconSize: 16
                    horizontalAlignment: Text.AlignHCenter
                    color: Appearance.m3colors.m3onSurfaceVariant
                }
            }
        }

        // Today button
        RippleButton {
            implicitWidth: todayRow.implicitWidth + 20
            implicitHeight: 36
            buttonRadius: Appearance.rounding.full
            downAction: () => root.goToToday()

            contentItem: RowLayout {
                id: todayRow
                spacing: 6

                MaterialSymbol {
                    text: "today"
                    iconSize: 18
                    color: Appearance.m3colors.m3primary
                }

                StyledText {
                    text: Translation.tr("Today")
                    color: Appearance.m3colors.m3primary
                    font.weight: Font.DemiBold
                }
            }

            StyledToolTip {
                text: Translation.tr("Go to today")
            }
        }

        // Close button
        RippleButton {
            implicitWidth: 36
            implicitHeight: 36
            buttonRadius: Appearance.rounding.full
            downAction: () => root.close()

            contentItem: MaterialSymbol {
                text: "close"
                iconSize: 20
                horizontalAlignment: Text.AlignHCenter
                color: Appearance.m3colors.m3onSurfaceVariant
            }
        }
    }
}
