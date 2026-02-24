# Apple Assistant

Bi-directional sync between **Apple Notes** and **Apple Reminders** — a local macOS automation that runs entirely on your machine.

Write `#act Buy groceries` in any Apple Note, and it automatically appears in your Reminders. Complete the reminder, and the note updates to `#done Buy groceries`.

## How It Works

```
Any Note:      #act Buy groceries
                 ↓ forward sync
Action List:   #act Buy groceries
                 ↓ forward sync
WORK list:     "Buy groceries" (reminder)
                 ↓ you complete it
                 ↓ reverse sync
Action List:   #done Buy groceries
Source Note:   #done Buy groceries
```

### Forward Sync (Notes → Reminders)
1. Scans all notes in the **Actions** folder for `#act` lines
2. Deduplicates and appends new actions to an **Action List** note
3. Creates matching reminders in the **WORK** reminders list

### Reverse Sync (Reminders → Notes)
4. Checks WORK list for completed reminders
5. Marks matching lines as `#done` in both the Action List and the original source note
6. Future scans skip `#done` lines automatically

## Requirements

- macOS (tested on macOS 15 Sequoia)
- Apple Notes and Apple Reminders
- A **Notes folder** called "Actions"
- A **Reminders list** called "WORK"

## Installation

```bash
git clone https://github.com/monbishnoi/apple-assistant.git
cd apple-assistant
bash setup.sh
```

On first trigger, macOS will prompt for Automation permissions — allow Terminal/bash to control Notes and Reminders. These can be managed in **System Settings > Privacy & Security > Automation**.

## Uninstallation

```bash
bash uninstall.sh
```

## Files

| File | Purpose |
|------|---------|
| `apple_assistant.sh` | Main agent — forward and reverse sync logic |
| `com.apple-assistant.plist` | launchd config — triggers on Notes/Reminders DB changes |
| `setup.sh` | One-time installer for the launchd agent |
| `uninstall.sh` | Clean uninstaller |
| `test_apple_assistant.sh` | Test suite (6 tests, 9 assertions) |

## How It Triggers

The agent uses `launchd` with `WatchPaths` to monitor:
- The Apple Notes SQLite database
- The Apple Reminders calendar store

When either file changes, the agent runs automatically (throttled to once every 15 seconds).

## Useful Commands

```bash
# Check if the agent is loaded
launchctl list | grep apple-assistant

# Watch live logs
tail -f apple_assistant.log

# Run manually
bash apple_assistant.sh
```

## Technical Details

- **No external dependencies** — pure shell script + AppleScript via `osascript`
- **No network calls** — everything runs locally
- **Idempotent** — safe to run multiple times
- **Lock file** prevents overlapping runs (stale locks cleared after 30s)
- **Log rotation** keeps the log file under 1000 lines

## License

MIT
