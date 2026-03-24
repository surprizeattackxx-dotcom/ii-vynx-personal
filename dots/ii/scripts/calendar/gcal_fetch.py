#!/usr/bin/env python3
"""
Fetch events from Google Calendar API using vdirsyncer OAuth tokens.
Reads credentials from vdirsyncer config at runtime — no secrets in code.

Usage:
  gcal_fetch.py [days_back] [days_forward]   — fetch events (default: 90 90)
  gcal_fetch.py list-calendars               — list writable calendars as JSON
"""

import json
import sys
from datetime import datetime, timedelta, timezone

import requests

from gcal_auth import get_authenticated_accounts, list_calendars


def fetch_events(access_token: str, calendar_id: str,
                 time_min: str, time_max: str) -> list[dict]:
    """Fetch events from a single calendar."""
    events = []
    page_token = None

    while True:
        params = {
            'timeMin': time_min,
            'timeMax': time_max,
            'singleEvents': 'true',
            'orderBy': 'startTime',
            'maxResults': 250,
        }
        if page_token:
            params['pageToken'] = page_token

        try:
            resp = requests.get(
                f'https://www.googleapis.com/calendar/v3/calendars/{calendar_id}/events',
                headers={'Authorization': f'Bearer {access_token}'},
                params=params,
                timeout=15,
            )
            if resp.status_code != 200:
                break

            data = resp.json()
            events.extend(data.get('items', []))

            page_token = data.get('nextPageToken')
            if not page_token:
                break
        except requests.RequestException:
            break

    return events


def format_event(event: dict, calendar_id: str, account_name: str,
                  calendar_color: str = '') -> dict | None:
    """Convert Google Calendar API event to khal-compatible JSON format."""
    start = event.get('start', {})
    end = event.get('end', {})

    start_str = start.get('dateTime') or start.get('date')
    end_str = end.get('dateTime') or end.get('date')

    if not start_str:
        return None

    is_all_day = 'date' in start and 'dateTime' not in start

    try:
        if is_all_day:
            start_dt = datetime.strptime(start_str, '%Y-%m-%d')
            end_dt = datetime.strptime(end_str, '%Y-%m-%d') if end_str else start_dt
        else:
            start_dt = datetime.fromisoformat(start_str)
            end_dt = datetime.fromisoformat(end_str) if end_str else start_dt
    except (ValueError, TypeError):
        return None

    title = event.get('summary', '(No title)')
    description = event.get('description', '')

    # Attendees and RSVP
    attendees_raw = event.get('attendees', [])
    attendees = []
    self_response = 'none'
    for att in attendees_raw:
        attendees.append({
            'email': att.get('email', ''),
            'displayName': att.get('displayName', ''),
            'responseStatus': att.get('responseStatus', ''),
        })
        if att.get('self'):
            self_response = att.get('responseStatus', 'needsAction')

    # Recurrence (original event may have recurrence rules)
    recurrence = event.get('recurrence', [])
    recurring_event_id = event.get('recurringEventId', '')

    return {
        'title': title,
        'start-date': start_dt.strftime('%d/%m/%Y'),
        'end-date': end_dt.strftime('%d/%m/%Y'),
        'start-time': '' if is_all_day else start_dt.strftime('%H:%M'),
        'end-time': '' if is_all_day else end_dt.strftime('%H:%M'),
        'description': description,
        'eventId': event.get('id', ''),
        'calendarId': calendar_id,
        'accountName': account_name,
        'source': 'gcal',
        'calendarColor': calendar_color,
        'attendees': attendees,
        'selfResponseStatus': self_response,
        'recurrence': recurrence,
        'recurringEventId': recurring_event_id,
    }


def cmd_list_calendars():
    """Output JSON array of writable calendars from all accounts."""
    result = []
    for account in get_authenticated_accounts():
        calendars = list_calendars(account['access_token'])
        for cal in calendars:
            role = cal.get('accessRole', '')
            if role in ('owner', 'writer'):
                result.append({
                    'accountName': account['name'],
                    'calendarId': cal.get('id', ''),
                    'calendarSummary': cal.get('summary', cal.get('id', '')),
                    'accessRole': role,
                    'backgroundColor': cal.get('backgroundColor', ''),
                })
    print(json.dumps(result), flush=True)


def cmd_fetch_events(days_back: int = 90, days_forward: int = 90):
    """Fetch events and output as JSON lines (one array per day)."""
    now = datetime.now(timezone.utc)
    time_min = (now - timedelta(days=days_back)).isoformat()
    time_max = (now + timedelta(days=days_forward)).isoformat()

    accounts = get_authenticated_accounts()
    if not accounts:
        print('[]', flush=True)
        return

    events_by_date: dict[str, list[dict]] = {}

    for account in accounts:
        calendars = list_calendars(account['access_token'])

        for cal in calendars:
            cal_id = cal.get('id', '')
            if cal.get('accessRole') not in ('owner', 'writer', 'reader'):
                continue

            cal_color = cal.get('backgroundColor', '')
            raw_events = fetch_events(account['access_token'], cal_id, time_min, time_max)

            for raw_evt in raw_events:
                evt = format_event(raw_evt, cal_id, account['name'], cal_color)
                if evt:
                    date_key = evt['start-date']
                    events_by_date.setdefault(date_key, []).append(evt)

    for date_key in sorted(events_by_date.keys(),
                           key=lambda d: datetime.strptime(d, '%d/%m/%Y')):
        print(json.dumps(events_by_date[date_key]), flush=True)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == 'list-calendars':
        cmd_list_calendars()
    else:
        days_back = int(sys.argv[1]) if len(sys.argv) > 1 else 90
        days_forward = int(sys.argv[2]) if len(sys.argv) > 2 else 90
        cmd_fetch_events(days_back, days_forward)


if __name__ == '__main__':
    main()
