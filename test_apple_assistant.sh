#!/bin/bash
# test_apple_assistant.sh — Test suite for apple_assistant.sh v2
# Creates test data in Apple Notes/Reminders, runs the agent, verifies results, cleans up.
# Uses SKIP_COMPILE=1 to bypass the shortcut and test the agent logic directly.

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

# Run the agent with the compile step skipped (tests set up Action List directly)
run_agent() {
    SKIP_COMPILE=1 bash "$AGENT"
}

# ── Setup ────────────────────────────────────────────────────────────────────

setup() {
    echo "=== Setting up test environment ==="

    # Stop the launchd daemon to prevent interference during testing
    launchctl unload ~/Library/LaunchAgents/com.apple-assistant.plist 2>/dev/null || true
    echo "  Daemon stopped for testing"

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

    # Create or clear Action List note with test actions
    if [[ "$ORIGINAL_ACTION_LIST" == "DOES_NOT_EXIST" ]]; then
        osascript -e '
tell application "Notes"
    make new note at folder "Actions" with properties {name:"Action List", body:"<div><b>Action List</b></div><div>#act Test action alpha</div><div>#act Test action beta</div>"}
end tell
'
        ORIGINAL_ACTION_LIST=""
    else
        # Set Action List to contain our test actions
        osascript -e '
tell application "Notes"
    set theNote to note "Action List" of folder "Actions"
    set body of theNote to "<div><b>Action List</b></div><div>#act Test action alpha</div><div>#act Test action beta</div>"
end tell
'
    fi

    # Delete any existing test note
    osascript -e "
tell application \"Notes\"
    try
        delete note \"$TEST_NOTE_NAME\" of folder \"Actions\"
    end try
end tell
" 2>/dev/null || true

    # Create test note with #act lines (source note for reverse sync)
    osascript -e "
tell application \"Notes\"
    make new note at folder \"Actions\" with properties {name:\"$TEST_NOTE_NAME\", body:\"<div><b>$TEST_NOTE_NAME</b></div><div>#act Test action alpha</div><div>#act Test action beta</div>\"}
end tell
"
    # Allow Apple Notes to index the new note
    sleep 1

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

    # Clean up lock file
    rm -f "$SCRIPT_DIR/apple_assistant.lock"

    # Restart the launchd daemon
    launchctl load ~/Library/LaunchAgents/com.apple-assistant.plist 2>/dev/null || true
    echo "  Daemon restarted"

    echo "=== Teardown complete ==="
}

# Always teardown, even on failure
trap teardown EXIT

# ── Test 1: Scan finds #act lines in source note ────────────────────────────

test_1_scan_finds_act_lines() {
    echo "Test 1: Scan finds #act lines in source notes"

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

# ── Test 2: Agent populates reminders from Action List ───────────────────────

test_2_forward_sync() {
    echo "Test 2: Forward sync — actions in Action List, reminders created"

    run_agent

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

    # Check reminders were created
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

    local rem_alpha=false rem_beta=false
    if echo "$reminders" | grep -qi "Test action alpha"; then rem_alpha=true; fi
    if echo "$reminders" | grep -qi "Test action beta"; then rem_beta=true; fi

    assert "WORK list has 'Test action alpha' reminder" "$rem_alpha"
    assert "WORK list has 'Test action beta' reminder" "$rem_beta"
}

# ── Test 3: Deduplication works ──────────────────────────────────────────────

test_3_deduplication() {
    echo "Test 3: Deduplication — duplicate lines removed"

    # Add a duplicate to the Action List
    osascript -e '
tell application "Notes"
    set theNote to note "Action List" of folder "Actions"
    set body of theNote to (body of theNote) & "<div>#act Test action alpha</div>"
end tell
'

    run_agent

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

# ── Test 4: Source note links added ──────────────────────────────────────────

test_4_source_refs() {
    echo "Test 4: Source note references added to Action List"

    local action_list_plain
    action_list_plain=$(osascript -e '
tell application "Notes"
    return plaintext of note "Action List" of folder "Actions"
end tell
')

    # Check that plaintext shows brackets around source note name for alpha
    local has_alpha_ref=false
    if echo "$action_list_plain" | grep -qi '#act Test action alpha \[Test Note - Apple Assistant\]'; then
        has_alpha_ref=true
    fi
    assert "Action List has '#act Test action alpha [Test Note - Apple Assistant]'" "$has_alpha_ref"

    # Check beta too
    local has_beta_ref=false
    if echo "$action_list_plain" | grep -qi '#act Test action beta \[Test Note - Apple Assistant\]'; then
        has_beta_ref=true
    fi
    assert "Action List has '#act Test action beta [Test Note - Apple Assistant]'" "$has_beta_ref"
}

# ── Test 5: Reverse sync — completed reminder marks #done ───────────────────

test_5_reverse_sync_done() {
    echo "Test 5: Reverse sync — completed reminder marks #done in Action List and source note"

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
    run_agent

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
}

# ── Test 6: Action List reorganized (#act on top, #done on bottom) ──────────

test_6_reorganization() {
    echo "Test 6: Action List reorganized (#act on top, separator, #done on bottom)"

    local action_list
    action_list=$(osascript -e '
tell application "Notes"
    return plaintext of note "Action List" of folder "Actions"
end tell
')

    # Find line numbers of #act, separator, and #done
    local act_line=0 sep_line=0 done_line=0 line_num=0
    while IFS= read -r line; do
        ((line_num++))
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if echo "$line" | grep -qi "^#act " && [[ "$act_line" -eq 0 ]]; then
            act_line=$line_num
        fi
        if [[ "$line" == "---" ]] && [[ "$sep_line" -eq 0 ]]; then
            sep_line=$line_num
        fi
        if echo "$line" | grep -qi "^#done " && [[ "$done_line" -eq 0 ]]; then
            done_line=$line_num
        fi
    done <<< "$action_list"

    local ordered=false
    # #act should come before separator, separator before #done
    if [[ "$act_line" -gt 0 && "$sep_line" -gt 0 && "$done_line" -gt 0 ]]; then
        if [[ "$act_line" -lt "$sep_line" && "$sep_line" -lt "$done_line" ]]; then
            ordered=true
        fi
    fi

    assert "Action List has #act (line $act_line) < separator (line $sep_line) < #done (line $done_line)" "$ordered"
}

# ── Test 7: Completed action not re-synced ──────────────────────────────────

test_7_no_resync_done() {
    echo "Test 7: Completed action not re-synced"

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
    run_agent

    # Verify "Test action alpha" was NOT re-created (it's #done in Action List)
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
    assert "'Test action alpha' reminder was NOT re-created (it's #done)" "$not_recreated"
}

# ── Run all tests ────────────────────────────────────────────────────────────

main() {
    setup

    test_1_scan_finds_act_lines
    echo ""
    test_2_forward_sync
    echo ""
    test_3_deduplication
    echo ""
    test_4_source_refs
    echo ""
    test_5_reverse_sync_done
    echo ""
    test_6_reorganization
    echo ""
    test_7_no_resync_done

    echo ""
    echo "=============================="
    echo "Results: $PASS passed, $FAIL failed"
    echo "=============================="

    if [[ "$FAIL" -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
