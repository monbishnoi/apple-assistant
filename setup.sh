#!/bin/bash
# setup.sh — Install the Apple Assistant launchd agent
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_NAME="com.apple-assistant.plist"
PLIST_SRC="$SCRIPT_DIR/$PLIST_NAME"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME"

echo "Apple Assistant — Setup"
echo "======================="
echo ""

# Check that the plist file exists
if [[ ! -f "$PLIST_SRC" ]]; then
    echo "ERROR: $PLIST_SRC not found"
    exit 1
fi

# Check that the main script exists and is executable
if [[ ! -x "$SCRIPT_DIR/apple_assistant.sh" ]]; then
    echo "ERROR: apple_assistant.sh not found or not executable"
    exit 1
fi

# Unload existing agent if loaded
if launchctl list | grep -q "com.apple-assistant"; then
    echo "Unloading existing agent..."
    launchctl unload "$PLIST_DST" 2>/dev/null || true
fi

# Create LaunchAgents directory if needed
mkdir -p "$HOME/Library/LaunchAgents"

# Copy plist to LaunchAgents
cp "$PLIST_SRC" "$PLIST_DST"
echo "Installed plist to $PLIST_DST"

# Load the agent
launchctl load "$PLIST_DST"
echo "Agent loaded."

echo ""
echo "Done! The agent will now run automatically when Notes or Reminders data changes."
echo ""
echo "NOTE: On first trigger, macOS will ask for Automation permissions."
echo "      Allow Terminal/bash to control Notes and Reminders."
echo ""
echo "To check status:  launchctl list | grep apple-assistant"
echo "To view logs:      tail -f $SCRIPT_DIR/apple_assistant.log"
echo "To uninstall:      bash $SCRIPT_DIR/uninstall.sh"
