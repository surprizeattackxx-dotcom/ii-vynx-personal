import QtQuick

QtObject {
    // Textual info
    required property string name
    property string statusText
    property string tooltipText: ""
    property string icon: "close"

    // State
    property bool hasStatusText: true
    property bool available: true
    property bool toggled: false

    // Interactions
    required property var mainAction
    property bool hasMenu: false
    property var altAction: null
    /** If true, altAction runs only on right-click (GroupButton), not on expanded left-click. */
    property bool rightClickOnlyAlt: false

    // Allow stuff like Processes to be declared freely
    default property list<QtObject> data
}
