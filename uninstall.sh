#!/bin/bash
# uninstall.sh — Remove the Apple Assistant launchd agent
set -euo pipefail

PLIST_NAME="com.apple-assistant.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Apple Assistant — Uninstall"
echo "==========================="
echo ""

# Unload the agent
if launchctl list | grep -q "com.apple-assistant"; then
    echo "Unloading agent..."
    launchctl unload "$PLIST_DST" 2>/dev/null || true
    echo "Agent unloaded."
else
    echo "Agent not currently loaded."
fi

# Remove plist
if [[ -f "$PLIST_DST" ]]; then
    rm "$PLIST_DST"
    echo "Removed $PLIST_DST"
else
    echo "Plist not found at $PLIST_DST (already removed)."
fi

# Clean up runtime files
rm -f "$SCRIPT_DIR/apple_assistant.lock"
rm -f "$SCRIPT_DIR/.source_map"
rm -f "$SCRIPT_DIR/launchd_stdout.log"
rm -f "$SCRIPT_DIR/launchd_stderr.log"

echo ""
echo "Uninstall complete. Log file preserved at: $SCRIPT_DIR/apple_assistant.log"
echo "To fully remove, delete the entire directory: $SCRIPT_DIR"
