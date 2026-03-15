pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root
    property var filePath: Directories.pinnedClipboardPath
    property list<string> pinned: []

    function getContent(entry) { return entry.replace(/^\d+\t/, "") }
    function isPinned(entry) { return pinned.indexOf(getContent(entry)) !== -1 }

    function pin(entry) {
        const c = getContent(entry)
        if (pinned.indexOf(c) === -1) { pinned = [...pinned, c]; save() }
    }
    function unpin(entry) {
        const c = getContent(entry)
        pinned = pinned.filter(p => p !== c)
        save()
    }
    function toggle(entry) { if (isPinned(entry)) unpin(entry); else pin(entry) }
    function save() { fileView.setText(JSON.stringify(pinned)) }

    FileView {
        id: fileView
        path: Qt.resolvedUrl(root.filePath)
        onLoaded: {
            try { root.pinned = JSON.parse(fileView.text()) } catch(e) { root.pinned = [] }
        }
        onLoadFailed: (error) => {
            if (error == FileViewError.FileNotFound) { root.pinned = []; fileView.setText("[]") }
        }
    }
    Component.onCompleted: fileView.reload()
}
