#!/usr/bin/env bash
# calendar.sh — Calendar operations for AI sidebar via khal.
# Usage:
#   calendar.sh list [days]           — list events for N days (default 3)
#   calendar.sh today                 — today's events
#   calendar.sh now                   — what's happening right now
#   calendar.sh add <args...>         — create event (khal new format)
#   calendar.sh search <query>        — search events in next 30 days
#   calendar.sh sync                  — sync with remote (vdirsyncer)

CMD="${1:-list}"
shift

case "$CMD" in
    list)
        DAYS="${1:-3}"
        khal list today "${DAYS}days" 2>&1
        ;;
    today)
        khal list today today 2>&1
        ;;
    now)
        CURRENT=$(khal at now 2>&1)
        if [[ -z "$CURRENT" ]]; then
            echo "No events happening right now."
            NEXT=$(khal list today 1days 2>&1 | head -5)
            if [[ -n "$NEXT" ]]; then
                echo ""
                echo "Upcoming today:"
                echo "$NEXT"
            fi
        else
            echo "$CURRENT"
        fi
        ;;
    add)
        if [[ $# -lt 1 ]]; then
            echo "Usage: calendar.sh add <start> [end] [summary] [:: description]"
            echo "Examples:"
            echo "  calendar.sh add '2026-03-23 14:00' '2026-03-23 15:00' 'Team standup'"
            echo "  calendar.sh add tomorrow 10:00 11:00 'Dentist appointment'"
            exit 1
        fi
        # Sync first to avoid conflicts
        vdirsyncer sync 2>/dev/null
        khal new "$@" 2>&1
        RESULT=$?
        if [[ $RESULT -eq 0 ]]; then
            echo "Event created. Syncing..."
            vdirsyncer sync 2>/dev/null
            echo "Done."
        fi
        ;;
    search)
        QUERY="$*"
        if [[ -z "$QUERY" ]]; then
            echo "Usage: calendar.sh search <query>"
            exit 1
        fi
        # Search events in the next 30 days
        EVENTS=$(khal list today 30days 2>&1)
        if [[ -z "$EVENTS" ]]; then
            echo "No events in the next 30 days."
        else
            MATCHED=$(echo "$EVENTS" | grep -i "$QUERY" -B1 -A0)
            if [[ -z "$MATCHED" ]]; then
                echo "No events matching '$QUERY' in the next 30 days."
            else
                echo "$MATCHED"
            fi
        fi
        ;;
    sync)
        echo "Syncing calendars..."
        vdirsyncer sync 2>&1
        echo "Done."
        ;;
    *)
        echo "Unknown command: $CMD"
        echo "Commands: list, today, now, add, search, sync"
        exit 1
        ;;
esac
