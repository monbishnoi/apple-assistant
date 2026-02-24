#!/bin/bash
# test_apple_assistant.sh — Test suite for apple_assistant.sh
# Creates test data in Apple Notes/Reminders, runs the agent, verifies results, cleans up.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT="$SCRIPT_DIR/apple_assistant.sh"
PASS=0
FAIL=0
NOTES_FOLDER="Actions"
TEST_NOTE_NAME="Test Note - Apple Assistant"
ACTION_LIST_NAME="Action List"
REMINDERS_LIST="WORK"

# ── Helpers ──────────────────────────────────────────────────────────────────

green() { printf "\033[32m%s\033[0m\n" "$1"; }
red()   { printf "\033[31m%s\033[0m\n" "$1"; }

assert() {
    local desc="$1" result="$2"
    if [[ "$result" == "true" ]]; then
        green "  PASS: $desc"
        ((PASS++))
    else
        red "  FAIL: $desc"
        ((FAIL++))
    fi
}

# ── Setup ────────────────────────────────────────────────────────────────────

setup() {
    echo "=== Setting up test environment ==="

    # Ensure Actions folder exists
    osascript -e '
tell application "Notes"
    try
        folder "Actions"
    on error
        make new folder with properties {name:"Actions"}
    end try
end tell
'

    # Save original Action List content (if exists)
    ORIGINAL_ACTION_LIST=$(osascript -e '
tell application "Notes"
    try
        set theNote to note "Action List" of folder "Actions"
        return body of theNote
    on error
        return "DOES_NOT_EXIST"
    end try
end tell
')

    # Create or clear Action List note
    if [[ "$ORIGINAL_ACTION_LIST" == "DOES_NOT_EXIST" ]]; then
        osascript -e '
tell application "Notes"
    make new note at folder "Actions" with properties {name:"Action List", body:"<div><b>Action List</b></div>"}
end tell
'
        ORIGINAL_ACTION_LIST=""
    fi

    # Delete any existing test note
    osascript -e "
tell application \"Notes\"
    try
        delete note \"$TEST_NOTE_NAME\" of folder \"Actions\"
    end try
end tell
" 2>/dev/null || true

    # Create test note with #act lines
    osascript -e "
tell application \"Notes\"
    make new note at folder \"Actions\" with properties {name:\"$TEST_NOTE_NAME\", body:\"<div><b>$TEST_NOTE_NAME</b></div><div>#act Test action alpha</div><div>#act Test action beta</div>\"}
end tell
"

    # Ensure WORK reminders list exists
    osascript -e '
tell application "Reminders"
    try
        list "WORK"
    on error
        make new list with properties {name:"WORK"}
    end try
end tell
'

    # Delete any pre-existing test reminders
    delete_test_reminders

    # Clean source map from previous runs
    rm -f "$SCRIPT_DIR/.source_map"

    echo "=== Setup complete ==="
    echo ""
}

# ── Teardown ─────────────────────────────────────────────────────────────────

delete_test_reminders() {
    osascript <<'APPLESCRIPT'
tell application "Reminders"
    try
        set theList to list "WORK"
        set allRems to every reminder of theList
        set toDelete to {}
        repeat with r in allRems
            if name of r is "Test action alpha" or name of r is "Test action beta" then
                set end of toDelete to r
            end if
        end repeat
        repeat with r in toDelete
            delete r
        end repeat
    end try
end tell
APPLESCRIPT
}

teardown() {
    echo ""
    echo "=== Tearing down test environment ==="

    # Delete test note
    osascript -e "
tell application \"Notes\"
    try
        delete note \"$TEST_NOTE_NAME\" of folder \"Actions\"
    end try
end tell
" 2>/dev/null || true

    # Restore original Action List content
    if [[ -n "$ORIGINAL_ACTION_LIST" && "$ORIGINAL_ACTION_LIST" != "DOES_NOT_EXIST" ]]; then
        local escaped="${ORIGINAL_ACTION_LIST//\"/\\\"}"
        osascript -e "
tell application \"Notes\"
    try
        set theNote to note \"Action List\" of folder \"Actions\"
        set body of theNote to \"$escaped\"
    end try
end tell
"
    fi

    # Delete test reminders
    delete_test_reminders

    # Clean up lock and source map
    rm -f "$SCRIPT_DIR/apple_assistant.lock"
    rm -f "$SCRIPT_DIR/.source_map"

    echo "=== Teardown complete ==="
}

# Always teardown, even on failure
trap teardown EXIT

# ── Test 1: Scan finds #act lines ───────────────────────────────────────────

test_1_scan_finds_act_lines() {
    echo "Test 1: Scan finds #act lines"

    local scan_output
    scan_output=$(osascript <<'APPLESCRIPT'
tell application "Notes"
    set output to ""
    set actionsFolder to folder "Actions"
    repeat with n in notes of actionsFolder
        if name of n is not "Action List" then
            set noteBody to plaintext of n
            set AppleScript's text item delimiters to {linefeed, return}
            set theLines to text items of noteBody
            set AppleScript's text item delimiters to ""
            repeat with aLine in theLines
                set trimmed to aLine as text
                if trimmed starts with "#act " then
                    set actionText to text 6 thru -1 of trimmed
                    set output to output & actionText & linefeed
                end if
            end repeat
        end if
    end repeat
    return output
end tell
APPLESCRIPT
)

    local found_alpha=false
    if echo "$scan_output" | grep -qi "Test action alpha"; then
        found_alpha=true
    fi
    assert "Scan output contains 'Test action alpha'" "$found_alpha"
}

# ── Test 2: Forward sync — new actions appear in Action List ────────────────

test_2_forward_sync_action_list() {
    echo "Test 2: Forward sync — new actions appear in Action List"

    bash "$AGENT"

    local action_list
    action_list=$(osascript -e '
tell application "Notes"
    return plaintext of note "Action List" of folder "Actions"
end tell
')

    local has_alpha=false has_beta=false
    if echo "$action_list" | grep -qi "Test action alpha"; then has_alpha=true; fi
    if echo "$action_list" | grep -qi "Test action beta"; then has_beta=true; fi

    assert "Action List contains 'Test action alpha'" "$has_alpha"
    assert "Action List contains 'Test action beta'" "$has_beta"
}

# ── Test 3: Forward sync — deduplication works ──────────────────────────────

test_3_deduplication() {
    echo "Test 3: Forward sync — deduplication works"

    # Run again — should not duplicate
    bash "$AGENT"

    local action_list
    action_list=$(osascript -e '
tell application "Notes"
    return plaintext of note "Action List" of folder "Actions"
end tell
')

    local count
    count=$(echo "$action_list" | grep -ci "Test action alpha" || true)

    local no_dup=false
    if [[ "$count" -eq 1 ]]; then no_dup=true; fi
    assert "Action List contains 'Test action alpha' exactly once (found $count)" "$no_dup"
}

# ── Test 4: Forward sync — reminders created ────────────────────────────────

test_4_reminders_created() {
    echo "Test 4: Forward sync — reminders created"

    local reminders
    reminders=$(osascript <<'APPLESCRIPT'
tell application "Reminders"
    try
        set theList to list "WORK"
        set allNames to name of every reminder of theList
        set output to ""
        repeat with n in allNames
            set output to output & (n as text) & linefeed
        end repeat
        return output
    on error
        return ""
    end try
end tell
APPLESCRIPT
)

    local has_alpha=false has_beta=false
    if echo "$reminders" | grep -qi "Test action alpha"; then has_alpha=true; fi
    if echo "$reminders" | grep -qi "Test action beta"; then has_beta=true; fi

    assert "WORK list has 'Test action alpha' reminder" "$has_alpha"
    assert "WORK list has 'Test action beta' reminder" "$has_beta"
}

# ── Test 5: Reverse sync — completed reminder marks #done ───────────────────

test_5_reverse_sync_done() {
    echo "Test 5: Reverse sync — completed reminder marks #done"

    # Mark "Test action alpha" as completed
    osascript <<'APPLESCRIPT'
tell application "Reminders"
    set theList to list "WORK"
    set allRems to every reminder of theList
    repeat with r in allRems
        if name of r is "Test action alpha" then
            set completed of r to true
        end if
    end repeat
end tell
APPLESCRIPT

    # Run the agent again
    bash "$AGENT"

    # Check source test note
    local source_note
    source_note=$(osascript -e "
tell application \"Notes\"
    return plaintext of note \"$TEST_NOTE_NAME\" of folder \"Actions\"
end tell
")

    local source_done=false
    if echo "$source_note" | grep -qi "#done Test action alpha"; then source_done=true; fi
    assert "Source note has '#done Test action alpha'" "$source_done"

    # Check Action List
    local action_list
    action_list=$(osascript -e '
tell application "Notes"
    return plaintext of note "Action List" of folder "Actions"
end tell
')

    local list_done=false
    if echo "$action_list" | grep -qi "#done Test action alpha"; then list_done=true; fi
    assert "Action List shows '#done' for 'Test action alpha'" "$list_done"
}

# ── Test 6: Completed action not re-synced ──────────────────────────────────

test_6_no_resync_done() {
    echo "Test 6: Completed action not re-synced"

    # Delete the completed reminder to simulate a clean state
    osascript <<'APPLESCRIPT'
tell application "Reminders"
    set theList to list "WORK"
    set allRems to every reminder of theList
    set toDelete to {}
    repeat with r in allRems
        if name of r is "Test action alpha" then
            set end of toDelete to r
        end if
    end repeat
    repeat with r in toDelete
        delete r
    end repeat
end tell
APPLESCRIPT

    # Allow Reminders to fully process the deletion
    sleep 2

    # Run agent again
    bash "$AGENT"

    # Verify "Test action alpha" was NOT re-created (it's #done in the source note)
    local reminders
    reminders=$(osascript <<'APPLESCRIPT'
tell application "Reminders"
    try
        set theList to list "WORK"
        set allNames to name of every reminder of theList
        set output to ""
        repeat with n in allNames
            set output to output & (n as text) & linefeed
        end repeat
        return output
    on error
        return ""
    end try
end tell
APPLESCRIPT
)

    local not_recreated=true
    if echo "$reminders" | grep -qi "Test action alpha"; then not_recreated=false; fi
    assert "'Test action alpha' reminder was NOT re-created (source is #done)" "$not_recreated"
}

# ── Run all tests ────────────────────────────────────────────────────────────

main() {
    setup

    test_1_scan_finds_act_lines
    echo ""
    test_2_forward_sync_action_list
    echo ""
    test_3_deduplication
    echo ""
    test_4_reminders_created
    echo ""
    test_5_reverse_sync_done
    echo ""
    test_6_no_resync_done

    echo ""
    echo "=============================="
    echo "Results: $PASS passed, $FAIL failed"
    echo "=============================="

    if [[ "$FAIL" -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
