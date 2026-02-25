#!/bin/bash
# apple_assistant.sh — Bi-directional sync between Apple Notes #act lines and Reminders
# v2: Deduplicates Action List, adds clickable source note links, syncs to WORK reminders.
# Completed reminders get marked #done in both Action List and source notes.
# Action List is reorganized: #act on top, separator, #done on bottom.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="$SCRIPT_DIR/apple_assistant.log"
LOCK_FILE="$SCRIPT_DIR/apple_assistant.lock"
MAX_LOG_LINES=1000
LOCK_TIMEOUT=30
NOTES_FOLDER="Actions"
ACTION_LIST_NOTE="Action List"
REMINDERS_LIST="WORK"

# ── Logging ──────────────────────────────────────────────────────────────────

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

rotate_log() {
    if [[ -f "$LOG_FILE" ]]; then
        local lines
        lines=$(wc -l < "$LOG_FILE")
        if (( lines > MAX_LOG_LINES )); then
            tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "$LOG_FILE.tmp"
            mv "$LOG_FILE.tmp" "$LOG_FILE"
        fi
    fi
}

# ── Lock file ────────────────────────────────────────────────────────────────

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_age
        lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_FILE") ))
        if (( lock_age > LOCK_TIMEOUT )); then
            log "WARN: Stale lock file (${lock_age}s old), removing"
            rm -f "$LOCK_FILE"
        else
            log "SKIP: Another instance running (lock age: ${lock_age}s)"
            exit 0
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

release_lock() {
    rm -f "$LOCK_FILE"
}

trap release_lock EXIT

# ── AppleScript helpers ──────────────────────────────────────────────────────

# Run the "compile action items" shortcut to populate the Action List note.
compile_actions() {
    log "Compile: running 'compile action items' shortcut"
    if shortcuts run "compile action items" 2>/dev/null; then
        log "Compile: shortcut completed successfully"
    else
        log "Compile: shortcut failed (exit code $?)"
        return 1
    fi
}

# Read the plaintext of the Action List note.
read_action_list() {
    osascript <<'APPLESCRIPT'
tell application "Notes"
    try
        set actionsFolder to folder "Actions"
        set theNote to note "Action List" of actionsFolder
        return plaintext of theNote
    on error
        return ""
    end try
end tell
APPLESCRIPT
}

# Read the HTML body of the Action List note.
read_action_list_html() {
    osascript <<'APPLESCRIPT'
tell application "Notes"
    try
        set actionsFolder to folder "Actions"
        set theNote to note "Action List" of actionsFolder
        return body of theNote
    on error
        return ""
    end try
end tell
APPLESCRIPT
}

# Write HTML body to the Action List note from a temp file.
write_action_list_html() {
    local html_file="$1"
    osascript <<APPLESCRIPT
tell application "Notes"
    set actionsFolder to folder "Actions"
    set theNote to note "Action List" of actionsFolder
    set newHTML to do shell script "cat '${html_file}'"
    set body of theNote to newHTML
end tell
APPLESCRIPT
}

# Read all reminder names (completed and incomplete) from WORK list.
# Returns tab-separated: name<TAB>completed (true/false)
read_reminders() {
    osascript <<'APPLESCRIPT'
tell application "Reminders"
    try
        set theList to list "WORK"
        set allNames to name of every reminder of theList
        set allCompleted to completed of every reminder of theList
        set output to ""
        repeat with i from 1 to count of allNames
            set output to output & (item i of allNames) & tab & (item i of allCompleted as text) & linefeed
        end repeat
        return output
    on error
        return ""
    end try
end tell
APPLESCRIPT
}

# Create reminders in the WORK list. Argument: newline-separated names.
create_reminders() {
    local names="$1"
    [[ -z "$names" ]] && return 0

    local script='tell application "Reminders"
    set theList to list "WORK"
'
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        # Escape double quotes for AppleScript
        local escaped="${name//\"/\\\"}"
        script="${script}    make new reminder at end of theList with properties {name:\"${escaped}\"}
"
    done <<< "$names"

    script="${script}end tell"
    osascript -e "$script"
}

# Get names of completed reminders from WORK list.
get_completed_reminders() {
    osascript <<'APPLESCRIPT'
tell application "Reminders"
    try
        set theList to list "WORK"
        set output to ""
        set allNames to name of every reminder of theList
        set allCompleted to completed of every reminder of theList
        repeat with i from 1 to count of allNames
            if item i of allCompleted then
                set output to output & (item i of allNames) & linefeed
            end if
        end repeat
        return output
    on error
        return ""
    end try
end tell
APPLESCRIPT
}

# Mark a line in the Action List note from #act to #done.
# Argument: action text (without prefix)
mark_done_in_action_list() {
    local action="$1"
    local escaped="${action//\"/\\\"}"
    osascript -e "
tell application \"Notes\"
    set actionsFolder to folder \"Actions\"
    set theNote to note \"Action List\" of actionsFolder
    set noteHTML to body of theNote
    set oldTag to \"#act ${escaped}\"
    set newTag to \"#done ${escaped}\"
    set AppleScript's text item delimiters to oldTag
    set parts to text items of noteHTML
    set AppleScript's text item delimiters to newTag
    set body of theNote to parts as text
    set AppleScript's text item delimiters to \"\"
end tell
"
}

# ── NEW v2: Build action→source note map ─────────────────────────────────────

# Scan all notes in Actions folder for #act lines.
# Returns tab-separated: action_text<TAB>note_name<TAB>note_id per line.
build_action_source_map() {
    osascript <<'APPLESCRIPT'
tell application "Notes"
    set actionsFolder to folder "Actions"
    set output to ""
    repeat with n in notes of actionsFolder
        if name of n is not "Action List" then
            set noteName to name of n
            set noteID to id of n
            set noteBody to plaintext of n
            set AppleScript's text item delimiters to {linefeed, return}
            set theLines to text items of noteBody
            set AppleScript's text item delimiters to ""
            repeat with aLine in theLines
                set trimmed to aLine as text
                if trimmed starts with "#act " then
                    set actionText to text 6 thru -1 of trimmed
                    set output to output & actionText & tab & noteName & tab & noteID & linefeed
                end if
            end repeat
        end if
    end repeat
    return output
end tell
APPLESCRIPT
}

# ── NEW v2: Deduplicate Action List ──────────────────────────────────────────

deduplicate_action_list() {
    log "Dedup: removing duplicate lines from Action List"

    local html_file result_file
    html_file=$(mktemp)
    result_file=$(mktemp)

    read_action_list_html > "$html_file"

    python3 - "$html_file" "$result_file" <<'PY'
import re, sys

with open(sys.argv[1]) as f:
    html = f.read()

# Match <div...>...</div> blocks
divs = re.findall(r'<div[^>]*>.*?</div>', html, re.DOTALL | re.IGNORECASE)

seen_keys = set()     # normalized keys for dedup
seen_actions = set()  # action text only (lowered), for #act vs #done dedup
unique = []

def normalize(text):
    """Normalize a line for dedup: strip [Source Note] brackets at end, lowercase."""
    t = re.sub(r'\s*\[[^\]]*\]\s*$', '', text).strip()
    return t.lower()

for div in divs:
    # Strip HTML tags to get text content
    text = re.sub(r'<[^>]+>', '', div).strip()

    if not text:
        continue

    # Skip old separators
    if text == '---':
        continue
    if '<hr' in div.lower():
        continue

    key = normalize(text)

    # Full line dedup (case-insensitive, ignoring bracket refs)
    if key in seen_keys:
        continue

    # Cross-prefix dedup: if #done version exists, skip new #act version
    if key.startswith('#act '):
        action_base = key[5:].strip()
        if '#done ' + action_base in seen_keys or action_base in seen_actions:
            continue
        seen_actions.add(action_base)
    elif key.startswith('#done '):
        action_base = key[6:].strip()
        seen_actions.add(action_base)

    seen_keys.add(key)
    unique.append(div)

with open(sys.argv[2], 'w') as f:
    f.write('\n'.join(unique))
PY

    write_action_list_html "$result_file"
    rm -f "$html_file" "$result_file"
    log "Dedup: Action List deduplicated"
}

# ── NEW v2: Add source note references ───────────────────────────────────────

# For each #act/#done line without a [Note Name] reference, find the source note
# and append [Note Name] in brackets. (Apple Notes strips <a> tags, so we use
# plain text brackets for source identification.)
add_source_refs() {
    log "Refs: adding source note references to Action List"

    local source_map_file html_file result_file
    source_map_file=$(mktemp)
    html_file=$(mktemp)
    result_file=$(mktemp)

    build_action_source_map > "$source_map_file"
    read_action_list_html > "$html_file"

    python3 - "$html_file" "$source_map_file" "$result_file" <<'PY'
import re, sys

with open(sys.argv[1]) as f:
    html = f.read()

with open(sys.argv[2]) as f:
    source_map_raw = f.read()

# Build source map: list of (action_text, note_name)
# Sorted by action_text length descending (longest match first)
source_entries = []
for line in source_map_raw.strip().split('\n'):
    parts = line.split('\t')
    if len(parts) >= 2:
        action_text = parts[0].strip()
        note_name = parts[1].strip()
        if action_text:
            source_entries.append((action_text, note_name))

source_entries.sort(key=lambda x: len(x[0]), reverse=True)

# Process each div in the HTML
divs = re.findall(r'<div[^>]*>.*?</div>', html, re.DOTALL | re.IGNORECASE)
processed = []

for div in divs:
    text = re.sub(r'<[^>]+>', '', div).strip()

    # Skip if already has brackets (source ref already added)
    if '[' in text:
        processed.append(div)
        continue

    lower = text.lower()
    if not (lower.startswith('#act ') or lower.startswith('#done ')):
        processed.append(div)
        continue

    # Get the part after prefix
    prefix_len = 5 if lower.startswith('#act ') else 6
    action_part = text[prefix_len:].strip()
    action_part_lower = action_part.lower()

    # Try to match against source map
    for action_text, note_name in source_entries:
        at_lower = action_text.lower().strip()
        nn_lower = note_name.lower().strip()

        # Case 1: line is exactly the action text
        if action_part_lower == at_lower:
            prefix = text[:prefix_len]
            new_content = f'{prefix}{action_text} [{note_name}]'
            div_match = re.match(r'(<div[^>]*>)(.*?)(</div>)', div, re.DOTALL | re.IGNORECASE)
            if div_match:
                div = f'{div_match.group(1)}{new_content}{div_match.group(3)}'
            break

        # Case 2: line is action_text + " " + note_name (shortcut appended note name)
        if action_part_lower == at_lower + ' ' + nn_lower:
            prefix = text[:prefix_len]
            new_content = f'{prefix}{action_text} [{note_name}]'
            div_match = re.match(r'(<div[^>]*>)(.*?)(</div>)', div, re.DOTALL | re.IGNORECASE)
            if div_match:
                div = f'{div_match.group(1)}{new_content}{div_match.group(3)}'
            break

    processed.append(div)

with open(sys.argv[3], 'w') as f:
    f.write('\n'.join(processed))
PY

    write_action_list_html "$result_file"
    rm -f "$source_map_file" "$html_file" "$result_file"
    log "Refs: source note references updated"
}

# ── NEW v2: Reorganize Action List ───────────────────────────────────────────

# Moves all #act items to top, adds a --- separator, then #done items below.
reorganize_action_list() {
    log "Reorg: reorganizing Action List (#act on top, #done on bottom)"

    local html_file result_file
    html_file=$(mktemp)
    result_file=$(mktemp)

    read_action_list_html > "$html_file"

    python3 - "$html_file" "$result_file" <<'PY'
import re, sys

with open(sys.argv[1]) as f:
    html = f.read()

divs = re.findall(r'<div[^>]*>.*?</div>', html, re.DOTALL | re.IGNORECASE)

title_divs = []
act_divs = []
done_divs = []
other_divs = []

for div in divs:
    text = re.sub(r'<[^>]+>', '', div).strip().lower()
    if not text or text == '---':
        continue  # Skip empty lines and old separators
    if '<hr' in div.lower():
        continue  # Skip old <hr> separators
    if '<b>' in div.lower() and 'action list' in text:
        title_divs.append(div)
    elif text.startswith('#act '):
        act_divs.append(div)
    elif text.startswith('#done '):
        done_divs.append(div)
    else:
        other_divs.append(div)

# Rebuild: title, #act items, other items, separator (if #done exists), #done items
result = title_divs + act_divs + other_divs
if done_divs:
    result.append('<div>---</div>')
    result.extend(done_divs)

with open(sys.argv[2], 'w') as f:
    f.write('\n'.join(result))
PY

    write_action_list_html "$result_file"
    rm -f "$html_file" "$result_file"
    log "Reorg: Action List reorganized"
}

# ── NEW v2: Mark done in source note ─────────────────────────────────────────

# Find the source note by name and change #act to #done for a given action.
mark_done_in_source_note() {
    local action="$1"
    local source_note_name="$2"
    local escaped_action="${action//\"/\\\"}"
    local escaped_note="${source_note_name//\"/\\\"}"

    log "Reverse sync: marking '#done' in source note '$source_note_name' for '$action'"

    osascript -e "
tell application \"Notes\"
    try
        set actionsFolder to folder \"Actions\"
        set theNote to note \"${escaped_note}\" of actionsFolder
        set noteHTML to body of theNote
        set oldTag to \"#act ${escaped_action}\"
        set newTag to \"#done ${escaped_action}\"
        set AppleScript's text item delimiters to oldTag
        set parts to text items of noteHTML
        set AppleScript's text item delimiters to newTag
        set body of theNote to parts as text
        set AppleScript's text item delimiters to \"\"
    on error errMsg
        -- Note not found or action not found, skip
    end try
end tell
" 2>/dev/null || log "Reverse sync: could not mark done in source note '$source_note_name'"
}

# ── Forward sync: Action List → Reminders ────────────────────────────────────

forward_sync() {
    log "Forward sync: reading Action List for #act lines"

    # 1. Read Action List (already deduplicated and linked)
    local action_list
    action_list=$(read_action_list)

    if [[ -z "$action_list" ]]; then
        log "Forward sync: Action List is empty"
        return 0
    fi

    # 2. Extract #act lines from Action List, stripping source note reference
    declare -a action_texts=()
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if echo "$line" | grep -qi "^#act "; then
            local action_text
            action_text=$(echo "$line" | sed 's/^#[aA][cC][tT] //')
            # Strip source note reference [Note Name] at end of line
            action_text=$(echo "$action_text" | sed 's/ *\[[^]]*\]$//')
            action_text=$(echo "$action_text" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -n "$action_text" ]] && action_texts+=("$action_text")
        fi
    done <<< "$action_list"

    if [[ ${#action_texts[@]} -eq 0 ]]; then
        log "Forward sync: no #act lines in Action List"
        return 0
    fi

    log "Forward sync: found ${#action_texts[@]} #act lines in Action List"

    # 3. Read existing reminders (both completed and incomplete)
    local existing_reminders
    existing_reminders=$(read_reminders)

    # 4. Find actions that don't have a reminder yet
    local new_reminders=""

    for action in "${action_texts[@]}"; do
        local action_lower
        action_lower=$(echo "$action" | tr '[:upper:]' '[:lower:]')

        local has_reminder=false
        while IFS=$'\t' read -r rem_name rem_completed; do
            local rem_lower
            rem_lower=$(echo "$rem_name" | tr '[:upper:]' '[:lower:]')
            if [[ "$rem_lower" == "$action_lower" ]]; then
                has_reminder=true
                break
            fi
        done <<< "$existing_reminders"

        if [[ "$has_reminder" == false ]]; then
            new_reminders="${new_reminders}${action}"$'\n'
        fi
    done

    # Remove trailing newlines
    new_reminders=$(echo "$new_reminders" | sed '/^$/d')

    # 5. Create new reminders
    if [[ -n "$new_reminders" ]]; then
        local count
        count=$(echo "$new_reminders" | wc -l | tr -d ' ')
        log "Forward sync: creating $count new reminders"
        create_reminders "$new_reminders"
    else
        log "Forward sync: no new reminders to create"
    fi
}

# ── Reverse sync: Reminders → Action List → Source Notes ─────────────────────

reverse_sync() {
    log "Reverse sync: checking for completed reminders"

    local completed
    completed=$(get_completed_reminders)

    if [[ -z "$completed" ]]; then
        log "Reverse sync: no completed reminders"
        return 0
    fi

    # Read Action List plaintext BEFORE marking done (to find source refs)
    local action_list
    action_list=$(read_action_list)

    while IFS= read -r rem_name; do
        [[ -z "$rem_name" ]] && continue
        rem_name=$(echo "$rem_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$rem_name" ]] && continue

        log "Reverse sync: '$rem_name' completed"

        # Find source note reference from Action List
        # Look for: #act <rem_name> [Source Note Name]
        local source_note=""
        while IFS= read -r al_line; do
            al_line=$(echo "$al_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if echo "$al_line" | grep -qi "^#act "; then
                local al_action
                al_action=$(echo "$al_line" | sed 's/^#[aA][cC][tT] //')
                # Extract source note name from brackets at end
                local bracket_ref
                bracket_ref=$(echo "$al_action" | grep -o '\[[^]]*\]$' | sed 's/^\[//;s/\]$//' || true)
                # Strip bracket ref to get pure action text
                local al_text
                al_text=$(echo "$al_action" | sed 's/ *\[[^]]*\]$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

                local al_lower rem_lower
                al_lower=$(echo "$al_text" | tr '[:upper:]' '[:lower:]')
                rem_lower=$(echo "$rem_name" | tr '[:upper:]' '[:lower:]')

                if [[ "$al_lower" == "$rem_lower" ]]; then
                    if [[ -n "$bracket_ref" ]]; then
                        source_note="$bracket_ref"
                    fi
                    break
                fi
            fi
        done <<< "$action_list"

        # Mark #done in Action List
        mark_done_in_action_list "$rem_name"

        # Mark #done in source note if found
        if [[ -n "$source_note" ]]; then
            mark_done_in_source_note "$rem_name" "$source_note"
        else
            log "Reverse sync: no source note reference found for '$rem_name'"
        fi
    done <<< "$completed"

    # Reorganize Action List: #act on top, separator, #done on bottom
    reorganize_action_list
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    rotate_log
    acquire_lock
    log "=== Apple Assistant v2 sync started ==="

    # Step 1: Run shortcut to compile #act lines into Action List
    if [[ "${SKIP_COMPILE:-}" != "1" ]]; then
        compile_actions
    else
        log "Compile: skipped (SKIP_COMPILE=1)"
    fi

    # Step 2: Deduplicate Action List
    deduplicate_action_list

    # Step 3: Add source note references [Note Name]
    add_source_refs

    # Step 4: Forward sync — Action List → Reminders
    forward_sync

    # Step 5: Reverse sync — Reminders → Action List → Source Notes + Reorganize
    reverse_sync

    log "=== Apple Assistant v2 sync completed ==="
}

main "$@"
