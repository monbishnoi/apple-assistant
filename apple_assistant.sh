#!/bin/bash
# apple_assistant.sh — Bi-directional sync between Apple Notes #act lines and Reminders
# Scans Notes for #act items, deduplicates into Action List note, syncs to WORK reminders.
# Completed reminders get marked #done in both Action List and source notes.

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

# Scan all notes in the Actions folder for #act lines (skips Action List note).
# Returns tab-separated: note_name<TAB>action_text
scan_notes_for_actions() {
    osascript <<'APPLESCRIPT'
tell application "Notes"
    set output to ""
    try
        set actionsFolder to folder "Actions"
    on error
        return ""
    end try
    repeat with n in notes of actionsFolder
        if name of n is not "Action List" then
            set noteTitle to name of n
            set noteBody to plaintext of n
            set AppleScript's text item delimiters to {linefeed, return}
            set theLines to text items of noteBody
            set AppleScript's text item delimiters to ""
            repeat with aLine in theLines
                set trimmed to aLine as text
                if trimmed starts with "#act " then
                    set actionText to text 6 thru -1 of trimmed
                    set output to output & noteTitle & tab & actionText & linefeed
                end if
            end repeat
        end if
    end repeat
    return output
end tell
APPLESCRIPT
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

# Append new actions to the Action List note (one per line as HTML divs).
# Argument: newline-separated action texts
append_to_action_list() {
    local actions="$1"
    [[ -z "$actions" ]] && return 0

    local html=""
    while IFS= read -r action; do
        [[ -z "$action" ]] && continue
        html="${html}<div>#act ${action}</div>"
    done <<< "$actions"

    [[ -z "$html" ]] && return 0

    osascript -e "
tell application \"Notes\"
    set actionsFolder to folder \"Actions\"
    set theNote to note \"Action List\" of actionsFolder
    set body of theNote to (body of theNote) & \"$html\"
end tell
"
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

# Mark #act → #done in the original source note.
# Arguments: note_name, action_text
mark_done_in_source_note() {
    local note_name="$1"
    local action="$2"
    local escaped_name="${note_name//\"/\\\"}"
    local escaped_action="${action//\"/\\\"}"
    osascript -e "
tell application \"Notes\"
    set actionsFolder to folder \"Actions\"
    try
        set theNote to note \"${escaped_name}\" of actionsFolder
        set noteHTML to body of theNote
        set oldTag to \"#act ${escaped_action}\"
        set newTag to \"#done ${escaped_action}\"
        set AppleScript's text item delimiters to oldTag
        set parts to text items of noteHTML
        set AppleScript's text item delimiters to newTag
        set body of theNote to parts as text
        set AppleScript's text item delimiters to \"\"
    on error errMsg
        -- Note may have been deleted, skip
    end try
end tell
"
}

# ── Forward sync: Notes → Action List → Reminders ───────────────────────────

forward_sync() {
    log "Forward sync: scanning notes for #act lines"

    # 1. Scan all notes for #act lines
    local raw_actions
    raw_actions=$(scan_notes_for_actions)

    if [[ -z "$raw_actions" ]]; then
        log "Forward sync: no #act lines found"
        return 0
    fi

    # Parse into parallel arrays: source notes and action texts
    declare -a source_notes=()
    declare -a action_texts=()
    while IFS=$'\t' read -r note_name action_text; do
        [[ -z "$action_text" ]] && continue
        # Trim whitespace
        action_text=$(echo "$action_text" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$action_text" ]] && continue
        source_notes+=("$note_name")
        action_texts+=("$action_text")
    done <<< "$raw_actions"

    log "Forward sync: found ${#action_texts[@]} #act lines"

    # 2. Read existing Action List
    local existing_list
    existing_list=$(read_action_list)

    # 3. Read existing reminders (both completed and incomplete)
    local existing_reminders
    existing_reminders=$(read_reminders)

    # 4. Deduplicate: find new actions not in Action List
    local new_actions=""
    local new_reminders=""
    # Also save the source mapping for reverse sync
    # Store source note → action mapping to a temp file for reverse sync
    local source_map_file="$SCRIPT_DIR/.source_map"
    : > "$source_map_file"

    for i in "${!action_texts[@]}"; do
        local action="${action_texts[$i]}"
        local source="${source_notes[$i]}"
        local action_lower
        action_lower=$(echo "$action" | tr '[:upper:]' '[:lower:]')

        # Save source mapping (always, for reverse sync)
        echo "${source}	${action}" >> "$source_map_file"

        # Check if already in Action List (case-insensitive)
        local in_list=false
        while IFS= read -r line; do
            local line_clean
            line_clean=$(echo "$line" | sed 's/^#act //;s/^#done //' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            local line_lower
            line_lower=$(echo "$line_clean" | tr '[:upper:]' '[:lower:]')
            if [[ "$line_lower" == "$action_lower" ]]; then
                in_list=true
                break
            fi
        done <<< "$existing_list"

        if [[ "$in_list" == false ]]; then
            new_actions="${new_actions}${action}"$'\n'
            log "Forward sync: new action: $action"
        fi

        # Check if reminder exists (case-insensitive, check both completed and incomplete)
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
    new_actions=$(echo "$new_actions" | sed '/^$/d')
    new_reminders=$(echo "$new_reminders" | sed '/^$/d')

    # 5. Append new actions to Action List
    if [[ -n "$new_actions" ]]; then
        local count
        count=$(echo "$new_actions" | wc -l | tr -d ' ')
        log "Forward sync: appending $count new actions to Action List"
        append_to_action_list "$new_actions"
    else
        log "Forward sync: no new actions to append"
    fi

    # 6. Create new reminders
    if [[ -n "$new_reminders" ]]; then
        local count
        count=$(echo "$new_reminders" | wc -l | tr -d ' ')
        log "Forward sync: creating $count new reminders"
        create_reminders "$new_reminders"
    else
        log "Forward sync: no new reminders to create"
    fi
}

# ── Reverse sync: Reminders → Action List → Notes ───────────────────────────

reverse_sync() {
    log "Reverse sync: checking for completed reminders"

    local completed
    completed=$(get_completed_reminders)

    if [[ -z "$completed" ]]; then
        log "Reverse sync: no completed reminders"
        return 0
    fi

    local source_map_file="$SCRIPT_DIR/.source_map"

    while IFS= read -r rem_name; do
        [[ -z "$rem_name" ]] && continue
        rem_name=$(echo "$rem_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$rem_name" ]] && continue

        log "Reverse sync: '$rem_name' completed"

        # Mark #done in Action List
        mark_done_in_action_list "$rem_name"

        # Find source note and mark #done there
        if [[ -f "$source_map_file" ]]; then
            while IFS=$'\t' read -r src_note src_action; do
                local src_lower rem_lower
                src_lower=$(echo "$src_action" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                rem_lower=$(echo "$rem_name" | tr '[:upper:]' '[:lower:]')
                if [[ "$src_lower" == "$rem_lower" ]]; then
                    log "Reverse sync: marking #done in source note '$src_note'"
                    mark_done_in_source_note "$src_note" "$src_action"
                    break
                fi
            done < "$source_map_file"
        fi
    done <<< "$completed"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    rotate_log
    acquire_lock
    log "=== Apple Assistant sync started ==="

    forward_sync
    reverse_sync

    log "=== Apple Assistant sync completed ==="
}

main "$@"
