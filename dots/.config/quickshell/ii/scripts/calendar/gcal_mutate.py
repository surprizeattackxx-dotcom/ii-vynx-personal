#!/usr/bin/env python3
"""
Create, update, delete, and RSVP Google Calendar events via the REST API.
Reads credentials from vdirsyncer config at runtime — no secrets in code.

Usage: gcal_mutate.py <action> <base64-json-payload>
  action: create | update | delete | rsvp
  payload: base64-encoded JSON object

Payload format:
  create:  {"accountName": "...", "calendarId": "...", "event": {summary, description, start, end}}
  update:  {"accountName": "...", "calendarId": "...", "eventId": "...", "event": {fields to update}}
  delete:  {"accountName": "...", "calendarId": "...", "eventId": "..."}
  rsvp:    {"accountName": "...", "calendarId": "...", "eventId": "...", "responseStatus": "accepted|declined|tentative"}

Output: {"ok": true, "eventId": "..."} or {"ok": false, "error": "..."}
"""

import base64
import json
import sys

import requests

from gcal_auth import find_account_by_name


def create_event(access_token: str, calendar_id: str, event_body: dict) -> dict:
    """Create a new event on the specified calendar."""
    try:
        resp = requests.post(
            f'https://www.googleapis.com/calendar/v3/calendars/{calendar_id}/events',
            headers={
                'Authorization': f'Bearer {access_token}',
                'Content-Type': 'application/json',
            },
            json=event_body,
            timeout=15,
        )
        if resp.status_code in (200, 201):
            data = resp.json()
            return {'ok': True, 'eventId': data.get('id', '')}
        else:
            return {'ok': False, 'error': f'HTTP {resp.status_code}: {resp.text[:200]}'}
    except requests.RequestException as e:
        return {'ok': False, 'error': str(e)}


def update_event(access_token: str, calendar_id: str, event_id: str, event_body: dict) -> dict:
    """Update an existing event."""
    try:
        resp = requests.patch(
            f'https://www.googleapis.com/calendar/v3/calendars/{calendar_id}/events/{event_id}',
            headers={
                'Authorization': f'Bearer {access_token}',
                'Content-Type': 'application/json',
            },
            json=event_body,
            timeout=15,
        )
        if resp.status_code == 200:
            data = resp.json()
            return {'ok': True, 'eventId': data.get('id', '')}
        else:
            return {'ok': False, 'error': f'HTTP {resp.status_code}: {resp.text[:200]}'}
    except requests.RequestException as e:
        return {'ok': False, 'error': str(e)}


def rsvp_event(access_token: str, calendar_id: str, event_id: str,
               response_status: str) -> dict:
    """Update the authenticated user's RSVP status on an event."""
    try:
        # GET the event to find current attendees
        resp = requests.get(
            f'https://www.googleapis.com/calendar/v3/calendars/{calendar_id}/events/{event_id}',
            headers={'Authorization': f'Bearer {access_token}'},
            timeout=15,
        )
        if resp.status_code != 200:
            return {'ok': False, 'error': f'GET failed: HTTP {resp.status_code}'}

        event = resp.json()
        attendees = event.get('attendees', [])

        # Find self and update responseStatus
        found = False
        for att in attendees:
            if att.get('self'):
                att['responseStatus'] = response_status
                found = True
                break

        if not found:
            return {'ok': False, 'error': 'Could not find self in attendees'}

        # PATCH with updated attendees
        return update_event(access_token, calendar_id, event_id, {'attendees': attendees})
    except requests.RequestException as e:
        return {'ok': False, 'error': str(e)}


def delete_event(access_token: str, calendar_id: str, event_id: str) -> dict:
    """Delete an event from the specified calendar."""
    try:
        resp = requests.delete(
            f'https://www.googleapis.com/calendar/v3/calendars/{calendar_id}/events/{event_id}',
            headers={'Authorization': f'Bearer {access_token}'},
            timeout=15,
        )
        if resp.status_code in (200, 204):
            return {'ok': True, 'eventId': event_id}
        else:
            return {'ok': False, 'error': f'HTTP {resp.status_code}: {resp.text[:200]}'}
    except requests.RequestException as e:
        return {'ok': False, 'error': str(e)}


def main():
    if len(sys.argv) < 3:
        print(json.dumps({'ok': False, 'error': 'Usage: gcal_mutate.py <action> <base64-payload>'}))
        sys.exit(1)

    action = sys.argv[1]
    try:
        payload = json.loads(base64.b64decode(sys.argv[2]).decode('utf-8'))
    except (json.JSONDecodeError, Exception) as e:
        print(json.dumps({'ok': False, 'error': f'Invalid payload: {e}'}))
        sys.exit(1)

    account_name = payload.get('accountName', '')
    calendar_id = payload.get('calendarId', '')

    if not account_name or not calendar_id:
        print(json.dumps({'ok': False, 'error': 'Missing accountName or calendarId'}))
        sys.exit(1)

    account, access_token = find_account_by_name(account_name)
    if not access_token:
        print(json.dumps({'ok': False, 'error': f'Could not authenticate account: {account_name}'}))
        sys.exit(1)

    if action == 'create':
        event_body = payload.get('event', {})
        result = create_event(access_token, calendar_id, event_body)
    elif action == 'update':
        event_id = payload.get('eventId', '')
        event_body = payload.get('event', {})
        if not event_id:
            result = {'ok': False, 'error': 'Missing eventId for update'}
        else:
            result = update_event(access_token, calendar_id, event_id, event_body)
    elif action == 'delete':
        event_id = payload.get('eventId', '')
        if not event_id:
            result = {'ok': False, 'error': 'Missing eventId for delete'}
        else:
            result = delete_event(access_token, calendar_id, event_id)
    elif action == 'rsvp':
        event_id = payload.get('eventId', '')
        response_status = payload.get('responseStatus', '')
        if not event_id or not response_status:
            result = {'ok': False, 'error': 'Missing eventId or responseStatus for rsvp'}
        else:
            result = rsvp_event(access_token, calendar_id, event_id, response_status)
    else:
        result = {'ok': False, 'error': f'Unknown action: {action}'}

    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    main()
