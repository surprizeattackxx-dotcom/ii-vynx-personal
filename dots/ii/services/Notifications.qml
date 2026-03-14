pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import qs
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications

/**
 * Provides extra features not in Quickshell.Services.Notifications:
 *  - Persistent storage
 *  - Popup notifications, with timeout
 *  - Notification groups by app
 *
 * M3 additions:
 *  - colorRole   : maps urgency → M3 semantic color container role
 *  - m3Priority  : int (0 = min … 4 = max) for sort ordering
 *  - popupList is sorted high → low priority so critical toasts always lead
 *  - Default timeout follows M3 range (4 000 – 10 000 ms) via Config
 *
 * Reply additions:
 *  - inlineReplySupported on the NotificationServer
 *  - replyingToId / replyingToSummary / replyingToAppName state
 *  - startReply(id) / cancelReply() / sendReply(id, text) API
 */
Singleton {
    id: root

    // ── M3 helpers ────────────────────────────────────────────────────────────

    function urgencyToColorRole(urgency) {
        switch (urgency) {
            case "critical": return "errorContainer";
            case "low":      return "surfaceContainerLow";
            default:         return "surfaceContainerHigh";
        }
    }

    function urgencyToM3Priority(urgency) {
        switch (urgency) {
            case "critical": return 4;
            case "low":      return 1;
            default:         return 2;
        }
    }

    // ── Notif component ───────────────────────────────────────────────────────

    component Notif: QtObject {
        id: wrapper
        required property int notificationId
        property Notification notification
        property list<var> actions: notification?.actions.map((action) => ({
            "identifier": action.identifier,
            "text": action.text,
        })) ?? []
        property bool popup: false
        property bool isTransient: notification?.hints.transient ?? false
        property string appIcon: notification?.appIcon ?? ""
        property string appName: notification?.appName ?? ""
        property string body: notification?.body ?? ""
        property string image: notification?.image ?? ""
        property string summary: notification?.summary ?? ""
        property double time
        property string urgency: notification?.urgency.toString() ?? "normal"
        property Timer timer

        // ── M3 properties ─────────────────────────────────────────────────────
        readonly property string colorRole: root.urgencyToColorRole(urgency)
        readonly property int m3Priority: root.urgencyToM3Priority(urgency)

        // ── Reply support ──────────────────────────────────────────────────────
        // True when the notification has an inline-reply action or when the
        // NotificationServer advertises inline-reply support and the app sent
        // a "reply" / "inline-reply" action identifier.
        readonly property bool hasReply: {
            if (notification === null) return false;
            return notification.actions.some((a) =>
            a.identifier === "inline-reply" ||
            a.identifier === "reply"
            );
        }

        onNotificationChanged: {
            if (notification === null) {
                root.discardNotification(notificationId);
            }
        }
    }

    function notifToJSON(notif) {
        return {
            "notificationId": notif.notificationId,
            "actions":        notif.actions,
            "appIcon":        notif.appIcon,
            "appName":        notif.appName,
            "body":           notif.body,
            "image":          notif.image,
            "summary":        notif.summary,
            "time":           notif.time,
            "urgency":        notif.urgency,
        }
    }
    function notifToString(notif) {
        return JSON.stringify(notifToJSON(notif), null, 2);
    }

    // ── NotifTimer ────────────────────────────────────────────────────────────

    component NotifTimer: Timer {
        required property int notificationId
        interval: 7000
        running: true
        onTriggered: () => {
            const index = root.list.findIndex((notif) => notif.notificationId === notificationId);
            const notifObject = root.list[index];
            print("[Notifications] Notification timer triggered for ID: " + notificationId + ", transient: " + notifObject?.isTransient);
            if (notifObject.isTransient) root.discardNotification(notificationId);
            else root.timeoutNotification(notificationId);
            destroy()
        }
    }

    // ── State ─────────────────────────────────────────────────────────────────

    property bool silent: false
    property int unread: 0
    property var filePath: Directories.notificationsPath
    property list<Notif> list: []

    property var popupList: list
    .filter((notif) => notif.popup)
    .sort((a, b) => b.m3Priority - a.m3Priority)

    property bool popupInhibited: (GlobalStates?.sidebarRightOpen ?? false) || silent
    property var latestTimeForApp: ({})

    // ── Reply state ───────────────────────────────────────────────────────────

    /// ID of the notification currently being replied to, or -1 when idle.
    property int replyingToId: -1
    /// Which surface opened the reply bar: "sidebar" or "popup"
    property string replySource: ""
    /// Human-readable fields surfaced to the reply UI.
    property string replyingToSummary: ""
    property string replyingToAppName: ""
    property string replyingToAppIcon: ""

    Component {
        id: notifComponent
        Notif {}
    }
    Component {
        id: notifTimerComponent
        NotifTimer {}
    }

    function stringifyList(list) {
        return JSON.stringify(list.map((notif) => notifToJSON(notif)), null, 2);
    }

    onListChanged: {
        root.list.forEach((notif) => {
            if (!root.latestTimeForApp[notif.appName] || notif.time > root.latestTimeForApp[notif.appName]) {
                root.latestTimeForApp[notif.appName] = Math.max(root.latestTimeForApp[notif.appName] || 0, notif.time);
            }
        });
        Object.keys(root.latestTimeForApp).forEach((appName) => {
            if (!root.list.some((notif) => notif.appName === appName)) {
                delete root.latestTimeForApp[appName];
            }
        });
    }

    function appNameListForGroups(groups) {
        return Object.keys(groups).sort((a, b) => {
            return groups[b].time - groups[a].time;
        });
    }

    function groupsForList(list) {
        const groups = {};
        list.forEach((notif) => {
            if (!groups[notif.appName]) {
                groups[notif.appName] = {
                    appName:       notif.appName,
                    appIcon:       notif.appIcon,
                    notifications: [],
                    time:          0
                };
            }
            groups[notif.appName].notifications.push(notif);
            groups[notif.appName].time = latestTimeForApp[notif.appName] || notif.time;
        });
        return groups;
    }

    property var groupsByAppName:      groupsForList(root.list)
    property var popupGroupsByAppName:  groupsForList(root.popupList)
    property list<string> appNameList:      appNameListForGroups(root.groupsByAppName)
    property list<string> popupAppNameList: appNameListForGroups(root.popupGroupsByAppName)

    property int idOffset
    signal initDone();
    signal notify(notification: var);
    signal discard(id: int);
    signal discardAll();
    signal timeout(id: var);
    /// Emitted when a reply is successfully sent (UI can clear its field).
    signal replySent(id: int, text: string);

    // ── Notification server ───────────────────────────────────────────────────

    NotificationServer {
        id: notifServer
        actionsSupported: true
        bodyHyperlinksSupported: true
        bodyImagesSupported: true
        bodyMarkupSupported: true
        bodySupported: true
        imageSupported: true
        inlineReplySupported: true   // ← advertise reply capability to senders
        keepOnReload: false
        persistenceSupported: true

        onNotification: (notification) => {
            notification.tracked = true
            const newNotifObject = notifComponent.createObject(root, {
                "notificationId": notification.id + root.idOffset,
                "notification":   notification,
                "time":           Date.now(),
            });
            root.list = [...root.list, newNotifObject];

            if (!root.popupInhibited) {
                newNotifObject.popup = true;
                if (notification.expireTimeout != 0) {
                    const rawTimeout = notification.expireTimeout < 0
                    ? (Config?.options.notifications.timeout ?? 7000)
                    : notification.expireTimeout;
                    const m3Timeout = Math.min(Math.max(rawTimeout, 4000), 10000);
                    newNotifObject.timer = notifTimerComponent.createObject(root, {
                        "notificationId": newNotifObject.notificationId,
                        "interval":       m3Timeout,
                    });
                }
                root.unread++;
            }
            root.notify(newNotifObject);
            notifFileView.setText(stringifyList(root.list));
        }
    }

    // ── Actions ───────────────────────────────────────────────────────────────

    function markAllRead() {
        root.unread = 0;
    }

    function discardNotification(id) {
        console.log("[Notifications] Discarding notification with ID: " + id);
        const index = root.list.findIndex((notif) => notif.notificationId === id);
        const notifServerIndex = notifServer.trackedNotifications.values.findIndex((notif) => notif.id + root.idOffset === id);
        if (index !== -1) {
            root.list.splice(index, 1);
            notifFileView.setText(stringifyList(root.list));
            triggerListChange()
        }
        if (notifServerIndex !== -1) {
            notifServer.trackedNotifications.values[notifServerIndex].dismiss()
        }
        // If the dismissed notification was the one being replied to, cancel.
        if (root.replyingToId === id) root.cancelReply();
        root.discard(id);
    }

    function discardAllNotifications() {
        root.list = []
        triggerListChange()
        notifFileView.setText(stringifyList(root.list));
        notifServer.trackedNotifications.values.forEach((notif) => {
            notif.dismiss()
        })
        root.cancelReply();
        root.discardAll();
    }

    function cancelTimeout(id) {
        const index = root.list.findIndex((notif) => notif.notificationId === id);
        if (root.list[index] != null)
            root.list[index].timer.stop();
    }

    function timeoutNotification(id) {
        const index = root.list.findIndex((notif) => notif.notificationId === id);
        if (root.list[index] != null)
            root.list[index].popup = false;
        root.timeout(id);
    }

    function timeoutAll() {
        root.popupList.forEach((notif) => {
            root.timeout(notif.notificationId);
        })
        root.popupList.forEach((notif) => {
            notif.popup = false;
        });
    }

    function attemptInvokeAction(id, notifIdentifier) {
        console.log("[Notifications] Attempting to invoke action with identifier: " + notifIdentifier + " for notification ID: " + id);
        const notifServerIndex = notifServer.trackedNotifications.values.findIndex((notif) => notif.id + root.idOffset === id);
        console.log("Notification server index: " + notifServerIndex);
        if (notifServerIndex !== -1) {
            const notifServerNotif = notifServer.trackedNotifications.values[notifServerIndex];
            const action = notifServerNotif.actions.find((action) => action.identifier === notifIdentifier);
            action.invoke()
        } else {
            console.log("Notification not found in server: " + id)
        }
        root.discardNotification(id);
    }

    // ── Reply API ──────────────────────────────────────────────────────────────

    /**
     * Begin a reply session for the given notification ID.
     * Sets replyingTo* properties so the UI can display a contextual input box.
     */
    function startReply(id, source) {
        const notif = root.list.find((n) => n.notificationId === id);
        if (!notif) return;
        root.replyingToId      = id;
        root.replySource       = source ?? "sidebar";
        root.replyingToSummary = notif.summary;
        root.replyingToAppName = notif.appName;
        root.replyingToAppIcon = notif.appIcon;
    }

    /**
     * Cancel an in-progress reply without sending anything.
     */
    function cancelReply() {
        root.replyingToId      = -1;
        root.replySource       = "";
        root.replyingToSummary = "";
        root.replyingToAppName = "";
        root.replyingToAppIcon = "";
    }

    /**
     * Send `replyText` back to the originating application via the
     * inline-reply or reply action, then discard the notification.
     *
     * Quickshell exposes Notification.sendReply(text) when the server
     * has inlineReplySupported: true. We fall back to invoking a
     * "reply" / "inline-reply" action identifier if that method is
     * not available (older Quickshell builds).
     */
    function sendReply(id, replyText) {
        if (replyText.trim() === "") return;
        console.log("[Notifications] Sending reply for ID " + id + ": " + replyText);

        const notifServerIndex = notifServer.trackedNotifications.values.findIndex(
            (notif) => notif.id + root.idOffset === id
        );

        if (notifServerIndex !== -1) {
            const serverNotif = notifServer.trackedNotifications.values[notifServerIndex];

            // Preferred path: Quickshell native inline-reply
            if (typeof serverNotif.sendReply === "function") {
                serverNotif.sendReply(replyText);
            } else {
                // Fallback: invoke the reply action if the app provided one
                const replyAction = serverNotif.actions.find((a) =>
                a.identifier === "inline-reply" || a.identifier === "reply"
                );
                if (replyAction) {
                    // Some action implementations accept a text argument
                    try { replyAction.invoke(replyText); }
                    catch (_) { replyAction.invoke(); }
                } else {
                    console.warn("[Notifications] No reply mechanism found for notification " + id);
                }
            }
        } else {
            console.warn("[Notifications] Notification " + id + " not found on server; cannot send reply.");
        }

        root.replySent(id, replyText);
        root.cancelReply();
        root.discardNotification(id);
    }

    function triggerListChange() {
        root.list = root.list.slice(0)
    }

    function refresh() {
        notifFileView.reload()
    }

    Component.onCompleted: {
        refresh()
    }

    // ── Persistence ───────────────────────────────────────────────────────────

    FileView {
        id: notifFileView
        path: Qt.resolvedUrl(filePath)
        onLoaded: {
            const fileContents = notifFileView.text()
            root.list = JSON.parse(fileContents).map((notif) => {
                return notifComponent.createObject(root, {
                    "notificationId": notif.notificationId,
                    "actions":        [],
                    "appIcon":        notif.appIcon,
                    "appName":        notif.appName,
                    "body":           notif.body,
                    "image":          notif.image,
                    "summary":        notif.summary,
                    "time":           notif.time,
                    "urgency":        notif.urgency,
                });
            });
            let maxId = 0
            root.list.forEach((notif) => {
                maxId = Math.max(maxId, notif.notificationId)
            })
            console.log("[Notifications] File loaded")
            root.idOffset = maxId
            root.initDone()
        }
        onLoadFailed: (error) => {
            if (error == FileViewError.FileNotFound) {
                console.log("[Notifications] File not found, creating new file.")
                root.list = []
                notifFileView.setText(stringifyList(root.list));
            } else {
                console.log("[Notifications] Error loading file: " + error)
            }
        }
    }
}
