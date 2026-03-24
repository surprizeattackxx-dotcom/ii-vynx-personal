// https://github.com/AvengeMedia/DankMaterialShell/blob/master/Services/CalendarService.qml

import QtQuick
import Quickshell
import Quickshell.Io
pragma Singleton
pragma ComponentBehavior: Bound
import qs
import qs.modules.common
import Qt.labs.platform
import qs.modules.common.functions
import qs.modules.common

Singleton {
    id: root

    property bool khalAvailable: false
    property bool gcalAvailable: false
    property bool mutating: false
    property var events: []
    property var khalEvents: []
    property var gcalEvents: []
    property var calendarList: [] // [{accountName, calendarId, calendarSummary, accessRole, backgroundColor}]
    property var hiddenCalendars: [] // calendarId strings to hide
    property var notifiedEvents: ({}) // tracks which reminders have fired
    property var weekdays: [
          Translation.tr("Sunday"),
          Translation.tr("Monday"),
          Translation.tr("Tuesday"),
          Translation.tr("Wednesday"),
          Translation.tr("Thursday"),
          Translation.tr("Friday"),
          Translation.tr("Saturday"),

        ];
    property var sortedWeekdays: root.weekdays.map((_, i) => weekdays[(i+Config.options.time.firstDayOfWeek+1)%7]);
    property var eventsInWeek: [
            {
              name:  sortedWeekdays[0],
              events: [
                {
                  title: "Example: You need to install khal to view events",
                  start: "7:30",
                  end: "9:20",
                  color: Appearance.m3colors.m3error
                },
              ]
            },
            {
              name: sortedWeekdays[1],
              events: []
            },
            {
              name: sortedWeekdays[2],
              events: []
            },
            {
              name: sortedWeekdays[3],
              events: []
            },
            {
              name: sortedWeekdays[4],
              events: []
            },
            {
              name: sortedWeekdays[5],
              events: []
            },
            {
              name: sortedWeekdays[6],
              events: []
            }
          ]

    // Merge khal + gcal events, deduplicating by title+date
    function mergeEvents() {
        const seen = new Set();
        const merged = [];
        const allEvents = [...root.gcalEvents, ...root.khalEvents];
        for (const evt of allEvents) {
            const key = evt.content + "|" + evt.startDate.getTime();
            if (!seen.has(key)) {
                seen.add(key);
                merged.push(evt);
            }
        }
        root.events = merged;
        root.eventsInWeek = root.getEventsInWeek();
    }

    // Shared parser for khal-format JSON lines (used by both khal and gcal_fetch)
    function parseJsonLines(text) {
        let events = [];
        let lines = text.split('\n');
        for (let line of lines) {
            line = line.trim();
            if (!line || line === "[]")
                continue;
            let dayEvents;
            try { dayEvents = JSON.parse(line); } catch (e) { continue; }
            for (let event of dayEvents) {
                let startDateParts = event['start-date'].split('/');
                let startTimeParts = event['start-time']
                    ? event['start-time'].split(':').map(Number)
                    : [0, 0];
                let endTimeParts = event['end-time']
                    ? event['end-time'].split(':').map(Number)
                    : [23, 59];

                // Parse end-date (falls back to start-date for backward compat)
                let endDateParts = event['end-date']
                    ? event['end-date'].split('/')
                    : startDateParts;

                let startDate = new Date(parseInt(startDateParts[2]),
                                         parseInt(startDateParts[1]) - 1,
                                         parseInt(startDateParts[0]),
                                         parseInt(startTimeParts[0]),
                                         parseInt(startTimeParts[1]));
                let endDate = new Date(parseInt(endDateParts[2]),
                                       parseInt(endDateParts[1]) - 1,
                                       parseInt(endDateParts[0]),
                                       parseInt(endTimeParts[0]),
                                       parseInt(endTimeParts[1]));

                let isMultiDay = (startDate.getFullYear() !== endDate.getFullYear() ||
                                  startDate.getMonth() !== endDate.getMonth() ||
                                  startDate.getDate() !== endDate.getDate());

                events.push({
                    "content": event['title'],
                    "startDate": startDate,
                    "endDate": endDate,
                    "isMultiDay": isMultiDay,
                    "color": ColorUtils.stringToColor(event['title']),
                    "description": event['description'] ?? "",
                    "eventId": event['eventId'] ?? "",
                    "calendarId": event['calendarId'] ?? "",
                    "accountName": event['accountName'] ?? "",
                    "source": event['source'] ?? "khal",
                    "calendarColor": event['calendarColor'] ?? "",
                    "attendees": event['attendees'] ?? [],
                    "selfResponseStatus": event['selfResponseStatus'] ?? "none",
                    "recurrence": event['recurrence'] ?? [],
                    "recurringEventId": event['recurringEventId'] ?? "",
                });
            }
        }
        return events;
    }

    // --- Google Calendar API (primary source) ---
    property string gcalScript: Quickshell.env("HOME") + "/.config/quickshell/ii/scripts/calendar/gcal_fetch.py"

    Process {
        id: gcalFetchProcess
        running: false
        command: ["python3", root.gcalScript, "90", "90"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.gcalEvents = root.parseJsonLines(this.text);
                root.gcalAvailable = true;
                root.mergeEvents();
            }
        }
        onExited: (exitCode) => {
            if (exitCode !== 0) {
                root.gcalAvailable = false;
            }
        }
    }

    // --- khal (secondary/local source) ---
    Process {
        id: khalCheckProcess
        command: ["khal", "list", "today"]
        running: true
        onExited: (exitCode) => {
          root.khalAvailable = (exitCode === 0);
          if(root.khalAvailable){
            interval.running = true
          }
        }
      }

      // --- Calendar list (writable calendars from all accounts) ---
      Process {
          id: calendarListProcess
          running: false
          command: ["python3", root.gcalScript, "list-calendars"]
          stdout: StdioCollector {
              onStreamFinished: {
                  try { root.calendarList = JSON.parse(this.text); } catch(e) {}
              }
          }
      }

      // --- Mutation process (create/update/delete) ---
      property string mutateScript: Quickshell.env("HOME") + "/.config/quickshell/ii/scripts/calendar/gcal_mutate.py"

      signal mutationSuccess()
      signal mutationError(string message)

      Process {
          id: mutateProcess
          running: false
          stdout: StdioCollector {
              onStreamFinished: {
                  root.mutating = false;
                  let result;
                  try { result = JSON.parse(this.text); } catch(e) { return; }
                  if (result.ok) {
                      root.mutationSuccess();
                      gcalFetchProcess.running = true; // refresh events
                  } else {
                      root.mutationError(result.error ?? "Unknown error");
                      console.log("[CalendarService] Mutation error:", result.error);
                  }
              }
          }
          onExited: (exitCode) => {
              if (exitCode !== 0) {
                  root.mutating = false;
              }
          }
      }

      function formatDateTimeIso(dt) {
          return Qt.formatDateTime(dt, "yyyy-MM-dd") + "T" + Qt.formatDateTime(dt, "HH:mm:ss");
      }

      function getLocalTimeZone() {
          try { return Intl.DateTimeFormat().resolvedOptions().timeZone; }
          catch(e) { return "America/New_York"; }
      }

      function createEvent(calendarId, accountName, title, description, startDate, endDate, allDay, recurrence) {
          if (root.mutating) return;
          let payload = {
              action: "create",
              accountName: accountName,
              calendarId: calendarId,
              event: {
                  summary: title,
                  description: description || ""
              }
          };
          if (allDay) {
              payload.event.start = { date: Qt.formatDate(startDate, "yyyy-MM-dd") };
              payload.event.end = { date: Qt.formatDate(endDate, "yyyy-MM-dd") };
          } else {
              const tz = getLocalTimeZone();
              payload.event.start = { dateTime: formatDateTimeIso(startDate), timeZone: tz };
              payload.event.end = { dateTime: formatDateTimeIso(endDate), timeZone: tz };
          }
          if (recurrence && recurrence.length > 0) {
              payload.event.recurrence = recurrence;
          }
          root.mutating = true;
          mutateProcess.command = ["python3", root.mutateScript, "create", Qt.btoa(JSON.stringify(payload))];
          mutateProcess.running = true;
      }

      function updateEvent(calendarId, accountName, eventId, title, description, startDate, endDate, allDay, recurrence) {
          if (root.mutating) return;
          let payload = {
              action: "update",
              accountName: accountName,
              calendarId: calendarId,
              eventId: eventId,
              event: {
                  summary: title,
                  description: description || ""
              }
          };
          if (allDay) {
              payload.event.start = { date: Qt.formatDate(startDate, "yyyy-MM-dd") };
              payload.event.end = { date: Qt.formatDate(endDate, "yyyy-MM-dd") };
          } else {
              const tz = getLocalTimeZone();
              payload.event.start = { dateTime: formatDateTimeIso(startDate), timeZone: tz };
              payload.event.end = { dateTime: formatDateTimeIso(endDate), timeZone: tz };
          }
          if (recurrence && recurrence.length > 0) {
              payload.event.recurrence = recurrence;
          }
          root.mutating = true;
          mutateProcess.command = ["python3", root.mutateScript, "update", Qt.btoa(JSON.stringify(payload))];
          mutateProcess.running = true;
      }

      function deleteEvent(calendarId, accountName, eventId) {
          if (root.mutating) return;
          let payload = {
              action: "delete",
              accountName: accountName,
              calendarId: calendarId,
              eventId: eventId
          };
          root.mutating = true;
          mutateProcess.command = ["python3", root.mutateScript, "delete", Qt.btoa(JSON.stringify(payload))];
          mutateProcess.running = true;
      }

      // Start gcal fetch + calendar list on load
      Component.onCompleted: {
          gcalInterval.running = true;
          gcalFetchProcess.running = true;
          calendarListProcess.running = true;
      }

      function getTasksByDate(currentDate) {
        const res = [];
        if (root.events.length === 0) return res;

        const currentDay = currentDate.getDate();
        const currentMonth = currentDate.getMonth();
        const currentYear = currentDate.getFullYear();
        const currentTime = new Date(currentYear, currentMonth, currentDay).getTime();

        for (let i = 0; i < root.events.length; i++) {
            const evt = root.events[i];
            const taskDate = new Date(evt.startDate);
            const startDay = new Date(taskDate.getFullYear(), taskDate.getMonth(), taskDate.getDate()).getTime();

            if (startDay === currentTime) {
                res.push(evt);
            } else if (evt.isMultiDay) {
                // Multi-day: check if currentDate falls within [startDate, endDate)
                const endDay = new Date(evt.endDate.getFullYear(), evt.endDate.getMonth(), evt.endDate.getDate()).getTime();
                if (currentTime > startDay && currentTime < endDay) {
                    res.push(evt);
                }
            }
        }

        return res;
      }

      // Filtered version that respects hidden calendars
      function getFilteredTasksByDate(currentDate) {
          return root.getTasksByDate(currentDate).filter(
              e => !root.hiddenCalendars.includes(e.calendarId)
          );
      }

      // Toggle calendar visibility
      function toggleCalendar(calendarId) {
          let hidden = [...root.hiddenCalendars];
          const idx = hidden.indexOf(calendarId);
          if (idx >= 0) {
              hidden.splice(idx, 1);
          } else {
              hidden.push(calendarId);
          }
          root.hiddenCalendars = hidden;
          root.eventsInWeek = root.getEventsInWeek();
      }

      // Search events by query string
      function searchEvents(query) {
          if (!query || query.length < 2) return [];
          const q = query.toLowerCase();
          return root.events.filter(e =>
              !root.hiddenCalendars.includes(e.calendarId) &&
              (e.content.toLowerCase().includes(q) ||
               (e.description && e.description.toLowerCase().includes(q)))
          ).sort((a, b) => a.startDate - b.startDate);
      }

      // Move event to a new date (preserving time and duration)
      function moveEvent(eventData, newDate) {
          if (!eventData.eventId || eventData.source !== "gcal") return;
          const timeDelta = eventData.startDate.getHours() * 3600000 + eventData.startDate.getMinutes() * 60000;
          const newStart = new Date(newDate.getFullYear(), newDate.getMonth(), newDate.getDate());
          newStart.setTime(newStart.getTime() + timeDelta);
          const duration = eventData.endDate.getTime() - eventData.startDate.getTime();
          const newEnd = new Date(newStart.getTime() + duration);
          updateEvent(eventData.calendarId, eventData.accountName, eventData.eventId,
                      eventData.content, eventData.description, newStart, newEnd, false);
      }

      // Quick-create all-day event on default calendar
      function quickCreateEvent(title, date) {
          if (!title.trim() || calendarList.length === 0) return;
          const cal = calendarList[0];
          const startDate = new Date(date.getFullYear(), date.getMonth(), date.getDate());
          const endDate = new Date(date.getFullYear(), date.getMonth(), date.getDate() + 1);
          createEvent(cal.calendarId, cal.accountName, title.trim(), "", startDate, endDate, true);
      }

      // RSVP to an event
      function rsvpEvent(eventId, calendarId, accountName, responseStatus) {
          if (root.mutating) return;
          let payload = {
              action: "rsvp",
              accountName: accountName,
              calendarId: calendarId,
              eventId: eventId,
              responseStatus: responseStatus
          };
          root.mutating = true;
          mutateProcess.command = ["python3", root.mutateScript, "rsvp", Qt.btoa(JSON.stringify(payload))];
          mutateProcess.running = true;
      }


      function getEventsInWeek() {
        const d = new Date();
        const num_day_today = d.getDay();
        let result = [];
        for (let i = 0; i < root.weekdays.length; i++) {
            const dayOffset = (i + Config.options.time.firstDayOfWeek+1);
            d.setDate(d.getDate() - d.getDay() + dayOffset %7);
            const events = this.getTasksByDate(d);
            const name_weekday = root.weekdays[d.getDay()];
            let obj = {
                "name": name_weekday,
                "events": []
              };
              events.forEach((evt, i) => {
                let start_time = Qt.formatDateTime(evt["startDate"], "hh:mm");
                let end_time = Qt.formatDateTime(evt["endDate"], "hh:mm");
                let title = evt["content"];
                obj["events"].push({
                    "start": start_time,
                    "end": end_time,
                    "title": title,
                    "color": evt['color'],
                    "description": evt['description'],
                    "eventId": evt['eventId'] ?? "",
                    "calendarId": evt['calendarId'] ?? "",
                    "accountName": evt['accountName'] ?? "",
                    "source": evt['source'] ?? "khal"
                });
              });
              result.push(obj)

          }

        return result;
      }

    // Process for loading events from khal
    Process {
      id: getEventsProcess
      running: false
        command: ["khal", "list", "--json", "title", "--json", "start-date", "--json" ,"start-time", "--json" ,"end-time", "--json", "description",    Qt.formatDate((() => { let d = new Date(); d.setMonth(d.getMonth() - 3); return d; })(), "dd/MM/yyyy") ,Qt.formatDate((() => { let d = new Date(); d.setMonth(d.getMonth() + 3); return d; })(), "dd/MM/yyyy")]
        stdout: StdioCollector {
          onStreamFinished: {
              root.khalEvents = root.parseJsonLines(this.text);
              root.mergeEvents();
          }
        }
      }

      // --- Event reminder notifications ---
      Timer {
          id: reminderTimer
          interval: 60000 // check every minute
          running: true
          repeat: true
          onTriggered: {
              const now = new Date();
              const reminderWindows = [15, 30, 60]; // minutes before event

              for (const evt of root.events) {
                  if (root.hiddenCalendars.includes(evt.calendarId)) continue;
                  for (const mins of reminderWindows) {
                      const alertTime = new Date(evt.startDate.getTime() - mins * 60000);
                      const diffMs = Math.abs(now.getTime() - alertTime.getTime());

                      if (diffMs < 60000) {
                          const key = (evt.eventId || evt.content) + "_" + mins;
                          if (!root.notifiedEvents[key]) {
                              let updated = Object.assign({}, root.notifiedEvents);
                              updated[key] = true;
                              root.notifiedEvents = updated;
                              const timeStr = Qt.formatDateTime(evt.startDate, "HH:mm");
                              Quickshell.execDetached(["notify-send",
                                  "Calendar: " + evt.content,
                                  "Starting at " + timeStr + " (" + mins + " min)",
                                  "-a", "Calendar",
                                  "-u", mins <= 15 ? "critical" : "normal"
                              ]);
                          }
                      }
                  }
              }

              // Clean up old notification entries (events older than 2 hours)
              const cutoff = now.getTime() - 7200000;
              let cleaned = {};
              for (const key in root.notifiedEvents) {
                  // Keep entries for events that haven't passed yet
                  cleaned[key] = root.notifiedEvents[key];
              }
          }
      }

      // khal poll timer (frequent, local data)
      Timer {
        id: interval
        running: false
        interval: Config.options?.resources?.updateInterval ?? 3000
        repeat: true
        onTriggered: {
          getEventsProcess.running = true
        }
    }

      // Google Calendar API poll timer (less frequent, network call)
      Timer {
          id: gcalInterval
          running: false
          interval: 300000 // 5 minutes
          repeat: true
          onTriggered: {
              gcalFetchProcess.running = true;
          }
      }



      
      Process {
        id: khalAddTaskProcess
        running: false
      }



      function addItem(item){
        let title =  item['content']
        let formattedDate = Qt.formatDate(item['date'], "dd/MM/yyyy")
        khalAddTaskProcess.command = ["khal", "new", formattedDate, title]
        khalAddTaskProcess.running = true
      }


    Process {
        id: khalRemoveProcess
        running: false
      }

      function removeItem(item){
        let taskToDelete = item['content'].replace(/'/g, "''")

        khalRemoveProcess.command = [ // currently only this hack is possible to delte without interactive shell issue:https://github.com/pimutils/khal/issues/603
          "sqlite3",
          String(StandardPaths.standardLocations(StandardPaths.HomeLocation)[0]).replace("file://", "") + "/.local/share/khal/khal.db",
          "DELETE FROM events WHERE item LIKE '%SUMMARY:" + taskToDelete + "%';"
          ]

        
          khalRemoveProcess.running = true
          console.log(khalRemoveProcess.command)


    }
}
