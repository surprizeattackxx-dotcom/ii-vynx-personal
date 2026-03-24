#!/usr/bin/env python3
"""
Shared Google Calendar OAuth authentication utilities.
Reads credentials from vdirsyncer config at runtime — no secrets in code.
"""

import json
import re
from datetime import datetime, timezone
from pathlib import Path

import requests

VDIRSYNCER_CONFIG = Path.home() / ".config" / "vdirsyncer" / "config"


def parse_vdirsyncer_config(config_path: Path | None = None) -> list[dict]:
    """Parse vdirsyncer config to find Google Calendar remote storages."""
    config_path = config_path or VDIRSYNCER_CONFIG
    if not config_path.exists():
        return []

    text = config_path.read_text()
    accounts = []

    storage_pattern = re.compile(
        r'\[storage\s+(\w+)\]\s*\n((?:(?!\[).+\n)*)', re.MULTILINE
    )

    for match in storage_pattern.finditer(text):
        name = match.group(1)
        block = match.group(2)

        if '"google_calendar"' not in block:
            continue

        token_file = None
        client_id = None
        client_secret = None

        for line in block.strip().split('\n'):
            line = line.strip()
            if line.startswith('token_file'):
                token_file = line.split('=', 1)[1].strip().strip('"')
            elif line.startswith('client_id'):
                client_id = line.split('=', 1)[1].strip().strip('"')
            elif line.startswith('client_secret'):
                client_secret = line.split('=', 1)[1].strip().strip('"')

        if token_file and client_id and client_secret:
            accounts.append({
                'name': name,
                'token_file': Path(token_file).expanduser(),
                'client_id': client_id,
                'client_secret': client_secret,
            })

    return accounts


def load_token(token_path: Path) -> dict | None:
    """Load OAuth token from vdirsyncer token file."""
    if not token_path.exists():
        return None
    try:
        return json.loads(token_path.read_text())
    except (json.JSONDecodeError, OSError):
        return None


def refresh_access_token(account: dict, token_data: dict) -> str | None:
    """Refresh the OAuth access token if expired."""
    expires_at = token_data.get('expires_at', 0)
    access_token = token_data.get('access_token')

    if access_token and expires_at > datetime.now(timezone.utc).timestamp() + 60:
        return access_token

    refresh_token = token_data.get('refresh_token')
    if not refresh_token:
        return access_token

    try:
        resp = requests.post('https://oauth2.googleapis.com/token', data={
            'client_id': account['client_id'],
            'client_secret': account['client_secret'],
            'refresh_token': refresh_token,
            'grant_type': 'refresh_token',
        }, timeout=10)

        if resp.status_code == 200:
            new_data = resp.json()
            token_data['access_token'] = new_data['access_token']
            token_data['expires_at'] = (
                datetime.now(timezone.utc).timestamp() + new_data.get('expires_in', 3600)
            )
            try:
                account['token_file'].write_text(json.dumps(token_data, indent=4))
            except OSError:
                pass
            return new_data['access_token']
    except requests.RequestException:
        pass

    return access_token


def list_calendars(access_token: str) -> list[dict]:
    """List all calendars for the account."""
    try:
        resp = requests.get(
            'https://www.googleapis.com/calendar/v3/users/me/calendarList',
            headers={'Authorization': f'Bearer {access_token}'},
            timeout=10,
        )
        if resp.status_code == 200:
            return resp.json().get('items', [])
    except requests.RequestException:
        pass
    return []


def get_authenticated_accounts() -> list[dict]:
    """Return accounts with valid access tokens attached.

    Each returned dict has the original account fields plus 'access_token'.
    """
    accounts = parse_vdirsyncer_config()
    authenticated = []
    for account in accounts:
        token_data = load_token(account['token_file'])
        if not token_data:
            continue
        access_token = refresh_access_token(account, token_data)
        if access_token:
            authenticated.append({**account, 'access_token': access_token})
    return authenticated


def find_account_by_name(account_name: str) -> tuple[dict, str] | tuple[None, None]:
    """Find a specific account by name and return (account, access_token)."""
    accounts = parse_vdirsyncer_config()
    for account in accounts:
        if account['name'] == account_name:
            token_data = load_token(account['token_file'])
            if not token_data:
                return None, None
            access_token = refresh_access_token(account, token_data)
            return account, access_token
    return None, None
