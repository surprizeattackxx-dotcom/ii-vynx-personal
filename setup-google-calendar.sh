#!/bin/bash
# Sets up Google Calendar sync for the ii-lacuna shell calendar widget.
# Uses vdirsyncer to sync Google Calendar → local ICS files → khal reads them.
#
# You will need a Google OAuth2 client ID and secret:
#   1. Go to https://console.cloud.google.com/
#   2. Create a new project (or select an existing one)
#   3. Enable the Google Calendar API
#   4. Go to APIs & Services → Credentials → Create Credentials → OAuth client ID
#   5. Application type: Desktop app
#   6. Copy the Client ID and Client Secret

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[1;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CREDS_FILE="$HOME/.config/illogical-impulse/google_calendar_creds"
VDIRSYNCER_CONFIG="$HOME/.config/vdirsyncer/config"
KHAL_CONFIG="$HOME/.config/khal/config"
CALENDAR_DIR="$HOME/.local/share/vdirsyncer/google_calendar"
STATUS_DIR="$HOME/.local/share/vdirsyncer/status"

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}     Google Calendar Sync Setup       ${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ── 1. Install vdirsyncer ───────────────────────────────────────────────────

if ! command -v vdirsyncer &>/dev/null; then
    echo -e "${BLUE}• Installing vdirsyncer...${NC}"
    if command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm vdirsyncer
    elif command -v apt &>/dev/null; then
        sudo apt install -y vdirsyncer
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y vdirsyncer
    else
        echo -e "${RED}✗ Could not auto-install vdirsyncer. Please install it manually and re-run.${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ vdirsyncer installed${NC}"
else
    echo -e "${GREEN}✓ vdirsyncer already installed${NC}"
fi

# ── 2. Google OAuth2 credentials ───────────────────────────────────────────

mkdir -p "$(dirname "$CREDS_FILE")"

if [ -f "$CREDS_FILE" ]; then
    source "$CREDS_FILE"
    echo -e "${GREEN}✓ Found saved credentials at $CREDS_FILE${NC}"
else
    echo ""
    echo -e "${YELLOW}You need a Google OAuth2 Client ID and Secret.${NC}"
    echo -e "${BLUE}Steps:${NC}"
    echo -e "  1. Open ${BLUE}https://console.cloud.google.com/${NC}"
    echo -e "  2. Create/select a project"
    echo -e "  3. Enable the ${BLUE}Google Calendar API${NC}"
    echo -e "  4. APIs & Services → Credentials → Create Credentials → OAuth client ID"
    echo -e "  5. Application type: ${YELLOW}Desktop app${NC}"
    echo -e "  6. Copy the Client ID and Client Secret below"
    echo ""

    read -rp "$(echo -e "${YELLOW}Enter Google OAuth2 Client ID: ${NC}")" GOOGLE_CLIENT_ID
    if [ -z "$GOOGLE_CLIENT_ID" ]; then
        echo -e "${RED}✗ Client ID cannot be empty.${NC}"
        exit 1
    fi

    read -rp "$(echo -e "${YELLOW}Enter Google OAuth2 Client Secret: ${NC}")" GOOGLE_CLIENT_SECRET
    if [ -z "$GOOGLE_CLIENT_SECRET" ]; then
        echo -e "${RED}✗ Client Secret cannot be empty.${NC}"
        exit 1
    fi

    echo "GOOGLE_CLIENT_ID=\"$GOOGLE_CLIENT_ID\"" > "$CREDS_FILE"
    echo "GOOGLE_CLIENT_SECRET=\"$GOOGLE_CLIENT_SECRET\"" >> "$CREDS_FILE"
    chmod 600 "$CREDS_FILE"
    echo -e "${GREEN}✓ Credentials saved to $CREDS_FILE${NC}"
fi

# ── 3. Create directories ───────────────────────────────────────────────────

mkdir -p "$CALENDAR_DIR" "$STATUS_DIR" "$HOME/.config/vdirsyncer"
echo -e "${GREEN}✓ Directories created${NC}"

# ── 4. Write vdirsyncer config (contains secrets, never committed) ──────────

cat > "$VDIRSYNCER_CONFIG" <<EOF
[general]
status_path = "$STATUS_DIR"

[pair google_calendar]
a = "google_calendar_local"
b = "google_calendar_remote"
collections = ["from b"]
metadata = ["color", "displayname"]

[storage google_calendar_local]
type = "filesystem"
path = "$CALENDAR_DIR"
fileext = ".ics"

[storage google_calendar_remote]
type = "google_calendar"
token_file = "$HOME/.local/share/vdirsyncer/google_token"
client_id = "$GOOGLE_CLIENT_ID"
client_secret = "$GOOGLE_CLIENT_SECRET"
EOF

chmod 600 "$VDIRSYNCER_CONFIG"
echo -e "${GREEN}✓ vdirsyncer config written to $VDIRSYNCER_CONFIG${NC}"

# ── 5. Install khal config ──────────────────────────────────────────────────

if [ ! -f "$KHAL_CONFIG" ]; then
    mkdir -p "$(dirname "$KHAL_CONFIG")"
    cp "$SCRIPT_DIR/dots/.config/khal/config" "$KHAL_CONFIG"
    echo -e "${GREEN}✓ khal config installed to $KHAL_CONFIG${NC}"
else
    echo -e "${YELLOW}⚠ $KHAL_CONFIG already exists, skipping (edit manually if needed)${NC}"
fi

# ── 6. Install systemd timer ────────────────────────────────────────────────

SYSTEMD_DIR="$HOME/.config/systemd/user"
mkdir -p "$SYSTEMD_DIR"

cp "$SCRIPT_DIR/dots/.config/systemd/user/vdirsyncer.service" "$SYSTEMD_DIR/"
cp "$SCRIPT_DIR/dots/.config/systemd/user/vdirsyncer.timer" "$SYSTEMD_DIR/"

systemctl --user daemon-reload
systemctl --user enable --now vdirsyncer.timer
echo -e "${GREEN}✓ vdirsyncer timer enabled (syncs every 15 minutes)${NC}"

# ── 7. Discover calendars (opens browser for OAuth) ─────────────────────────

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Authorizing with Google (step 1/2)  ${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}A browser window will open for you to authorize access to your Google Calendar.${NC}"
echo -e "${YELLOW}After authorizing, vdirsyncer will discover your calendars.${NC}"
echo ""
echo -e "${YELLOW}When prompted \"Do you want to sync?\", type ${GREEN}yes${YELLOW} and press Enter.${NC}"
echo ""

vdirsyncer discover google_calendar

if [ $? -ne 0 ]; then
    echo ""
    echo -e "${RED}✗ Calendar discovery failed. Check the error above.${NC}"
    echo -e "${YELLOW}You can re-run this script to try again.${NC}"
    exit 1
fi

# ── 8. Initial sync ─────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}      Initial sync (step 2/2)         ${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

vdirsyncer sync

if [ $? -ne 0 ]; then
    echo ""
    echo -e "${RED}✗ Initial sync failed. Check the error above.${NC}"
    exit 1
fi

# ── Done ────────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}   Google Calendar sync is ready!    ${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${NC}Your calendar events will now appear in:${NC}"
echo -e "  • The ${BLUE}sidebar calendar widget${NC}"
echo -e "  • The ${BLUE}clock popup${NC} (click the clock in the bar)"
echo -e "  • The ${BLUE}cheatsheet timetable${NC} (weekly view)"
echo ""
echo -e "${NC}Syncs automatically every 15 minutes via systemd timer.${NC}"
echo -e "${NC}To sync manually: ${YELLOW}vdirsyncer sync${NC}"
echo ""
