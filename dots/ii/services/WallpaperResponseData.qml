import qs.modules.common
import QtQuick;

/**
 * A booru response.
 */
QtObject {
    property string provider
    property var tags
    property var page
    property var images
    property string message
    property string filePath
    property string monitor  // which monitor this entry is for (empty = all)
}
