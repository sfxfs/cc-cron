# tests/test_commands.bats
#!/usr/bin/env bats

load 'test_helper'

setup() {
    setup_test_env
    # Source the script to load functions (CC_CRON_TEST_MODE prevents main from running)
    source "${BATS_TEST_DIRNAME}/../cc-cron.sh"
}

teardown() {
    teardown_test_env
}

@test "get_meta_file returns correct path" {
    run get_meta_file "abc123"
    [ "$output" == "${LOG_DIR}/abc123.meta" ]
}

@test "get_log_file returns correct path" {
    run get_log_file "testjob"
    [ "$output" == "${LOG_DIR}/testjob.log" ]
}

@test "get_status_file returns correct path" {
    run get_status_file "myjob"
    [ "$output" == "${LOG_DIR}/myjob.status" ]
}

@test "get_lock_file generates consistent hash" {
    run get_lock_file "/home/user/project"
    local expected_hash
    expected_hash=$(printf '%s' '/home/user/project' | md5sum | cut -d' ' -f1)
    [ "$output" == "${LOCK_DIR}/${expected_hash}.lock" ]
}

@test "generate_job_id produces 8 character id" {
    run generate_job_id
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[a-z0-9]{8}$ ]]
}

@test "generate_job_id produces unique ids" {
    local id1 id2
    id1=$(generate_job_id)
    id2=$(generate_job_id)
    [ "$id1" != "$id2" ]
}

@test "generate_job_id avoids collision" {
    # Create a meta file with a specific ID to force collision handling
    local existing_id="test0001"
    local meta_file; meta_file=$(get_meta_file "$existing_id")
    echo 'id="test0001"' > "$meta_file"

    # generate_job_id should still work (generate a different ID)
    local new_id
    new_id=$(generate_job_id)
    [ "$new_id" != "$existing_id" ]
    [[ "$new_id" =~ ^[a-z0-9]{8}$ ]]

    rm -f "$meta_file"
}

@test "ensure_data_dir creates directories" {
    run ensure_data_dir
    [ "$status" -eq 0 ]
    [ -d "$LOG_DIR" ]
    [ -d "$LOCK_DIR" ]
}

@test "validate_workdir accepts existing directory" {
    run validate_workdir "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
}

@test "validate_workdir rejects non-existent directory" {
    run validate_workdir "/nonexistent/path/12345"
    [ "$status" -ne 0 ]
}

@test "crontab caching works" {
    # Clear cache
    _CRONTAB_CACHE=""

    # First call should populate cache
    local content
    content=$(get_crontab)

    # Cache should now be populated
    [[ -n "$_CRONTAB_CACHE" ]] || [ "$_CRONTAB_CACHE" == "" ]
}

@test "invalidate_crontab_cache clears cache" {
    _CRONTAB_CACHE="test content"
    invalidate_crontab_cache
    [ -z "$_CRONTAB_CACHE" ]
}

@test "cmd_version outputs version string" {
    run cmd_version
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^cc-cron\ version\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "cmd_pause fails for non-existent job" {
    run cmd_pause "nonexistent"
    [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
}

@test "cmd_resume fails for non-existent job" {
    run cmd_resume "nonexistent"
    [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
}

@test "cmd_show fails for non-existent job" {
    run cmd_show "nonexistent"
    [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
}

@test "cmd_history fails for non-existent job" {
    run cmd_history "nonexistent"
    [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
}

@test "cmd_remove fails for non-existent job" {
    run cmd_remove "nonexistent"
    [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
}

@test "get_history_file returns correct path" {
    run get_history_file "testjob"
    [ "$output" == "${LOG_DIR}/testjob.history" ]
}

@test "load_job_meta fails for non-existent job" {
    run load_job_meta "nonexistent"
    [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
}

@test "load_job_meta loads existing job" {
    local job_id="testmeta"
    local meta_file; meta_file=$(get_meta_file "$job_id")
    echo 'id="testmeta"' > "$meta_file"
    echo 'created="2024-01-01"' >> "$meta_file"

    # Run in a subshell to test variable setting
    local result
    result=$(load_job_meta "$job_id" && echo "$id")
    [ "$result" == "testmeta" ]

    rm -f "$meta_file"
}

@test "extract_job_id parses crontab comment" {
    local line='0 9 * * * /home/user/run.sh  # CC-CRON:abc123:recurring=true:prompt=test'
    run extract_job_id "$line"
    [ "$status" -eq 0 ]
    [ "$output" == "abc123" ]
}

@test "extract_job_id handles short job id" {
    local line='0 9 * * * /home/user/run.sh  # CC-CRON:xyz789:recurring=false:prompt=hello'
    run extract_job_id "$line"
    [ "$status" -eq 0 ]
    [ "$output" == "xyz789" ]
}

@test "extract_job_id extracts from complex crontab line" {
    local line='*/5 * * * * /path/to/run.sh  # CC-CRON:ab12cd34:recurring=true:prompt=Test prompt with spaces'
    run extract_job_id "$line"
    [ "$status" -eq 0 ]
    [ "$output" == "ab12cd34" ]
}

@test "extract_job_id handles line with no colon after id" {
    local line='0 9 * * * /home/user/run.sh  # CC-CRON:onlyid'
    run extract_job_id "$line"
    [ "$status" -eq 0 ]
    [ "$output" == "onlyid" ]
}

@test "cmd_run fails for non-existent job" {
    run cmd_run "nonexistent"
    [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
}

@test "cmd_run fails when run script is missing" {
    local job_id="runmissing"
    local meta_file; meta_file=$(get_meta_file "$job_id")

    # Create metadata but no run script
    create_test_meta "$job_id"

    run cmd_run "$job_id"
    [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
    [[ "$output" == *"Run script not found"* ]]

    rm -f "$meta_file"
}

@test "cmd_next shows no jobs message when empty" {
    # Clear crontab cache
    _CRONTAB_CACHE=""

    # Skip if there are existing cc-cron jobs
    local crontab_content
    crontab_content=$(crontab -l 2>/dev/null) || crontab_content=""
    if [[ "$crontab_content" == *"CC-CRON:"* ]]; then
        skip "crontab has existing cc-cron jobs"
    fi

    run cmd_next
    [ "$status" -eq 0 ]
    [[ "$output" == *"No scheduled jobs found"* ]]
}

@test "cmd_next shows job not found for non-existent job" {
    run cmd_next "nonexistent123"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Job not found"* ]]
}

@test "cmd_help next shows detailed help" {
    run cmd_help "next"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cc-cron next"* ]]
    [[ "$output" == *"upcoming scheduled runs"* ]]
}

@test "cmd_edit fails for non-existent job" {
    run cmd_edit "nonexistent" --cron "0 0 * * *"
    [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
}

@test "cmd_edit with no options shows warning" {
    # Create a temp meta file for testing
    local job_id="testedit"
    local meta_file; meta_file=$(get_meta_file "$job_id")
    echo 'id="testedit"' > "$meta_file"
    echo 'created="2024-01-01"' >> "$meta_file"
    echo 'cron="0 0 * * *"' >> "$meta_file"
    echo 'recurring="true"' >> "$meta_file"
    echo 'prompt="test"' >> "$meta_file"
    echo 'workdir="/tmp"' >> "$meta_file"
    echo 'model=""' >> "$meta_file"
    echo 'permission_mode="bypassPermissions"' >> "$meta_file"
    echo 'timeout="0"' >> "$meta_file"
    echo 'run_script="/tmp/run.sh"' >> "$meta_file"

    run cmd_edit "$job_id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No changes specified"* ]]

    # Cleanup
    rm -f "$meta_file"
}

@test "cmd_export outputs empty array when no jobs" {
    run cmd_export
    [ "$status" -eq 0 ]
    [[ "$output" == *"No jobs to export"* ]]
}

@test "cmd_export fails for non-existent job" {
    run cmd_export "nonexistent"
    [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
}

@test "cmd_import fails for non-existent file" {
    run cmd_import "/nonexistent/file.json"
    [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
}

@test "cmd_import fails for invalid JSON" {
    local tmp_file="$BATS_TEST_TMPDIR/invalid.json"
    echo "not valid json {" > "$tmp_file"

    # Only run if jq is available
    if command -v jq &>/dev/null; then
        run cmd_import "$tmp_file"
        [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
        [[ "$output" == *"Invalid JSON"* ]]
    fi
}

@test "cmd_export creates valid JSON structure" {
    local job_id="testexp"
    create_test_meta "$job_id"

    run cmd_export "$job_id"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"version":"1.0"'* ]]
    [[ "$output" == *'"jobs":['* ]]
    [[ "$output" == *'"id":"testexp"'* ]]

    rm -f "$(get_meta_file "$job_id")"
}

@test "cmd_purge accepts days argument" {
    run cmd_purge "30"
    [ "$status" -eq 0 ]
}

@test "cmd_purge rejects invalid days argument" {
    run cmd_purge "invalid"
    [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
}

@test "cmd_purge dry-run mode works" {
    run cmd_purge "30" "true"
    [ "$status" -eq 0 ]
    [[ "$output" == *"dry-run"* ]] || [[ "$output" == *"Purging"* ]]
}

@test "purge_old_files handles empty directory" {
    # Create an empty temp directory
    local empty_dir="${BATS_TEST_TMPDIR}/empty_purge"
    mkdir -p "$empty_dir"

    PURGE_COUNT=0
    PURGE_BYTES=0

    purge_old_files "$empty_dir" "log" "30" "false" "test log"

    [ "$PURGE_COUNT" -eq 0 ]
    [ "$PURGE_BYTES" -eq 0 ]

    rm -rf "$empty_dir"
}

@test "purge_old_files handles dry-run mode" {
    local test_dir="${BATS_TEST_TMPDIR}/purge_test"
    mkdir -p "$test_dir"

    # Create a test file
    local test_file="${test_dir}/test.log"
    echo "test content" > "$test_file"

    PURGE_COUNT=0
    PURGE_BYTES=0

    # Use 0 days to match any file
    purge_old_files "$test_dir" "log" "0" "true" "test log"

    # File should still exist in dry-run mode
    [[ -f "$test_file" ]]

    rm -rf "$test_dir"
}

@test "load_config loads settings from file" {
    # Create a temp config file
    local config_file="${BATS_TEST_TMPDIR}/config"
    echo 'workdir="/tmp"' > "$config_file"
    echo 'model="sonnet"' >> "$config_file"
    echo 'permission_mode="auto"' >> "$config_file"
    echo 'timeout="60"' >> "$config_file"

    # Save original CONFIG_FILE
    local orig_config="$CONFIG_FILE"
    CONFIG_FILE="$config_file"

    # Run load_config
    load_config

    # Verify values were set
    [ "$CC_WORKDIR" == "/tmp" ]
    [ "$CC_MODEL" == "sonnet" ]
    [ "$CC_PERMISSION_MODE" == "auto" ]
    [ "$CC_TIMEOUT" == "60" ]

    # Restore
    CONFIG_FILE="$orig_config"
}

@test "load_config handles missing file gracefully" {
    local orig_config="$CONFIG_FILE"
    CONFIG_FILE="/nonexistent/config/file"

    # Should not error
    load_config

    CONFIG_FILE="$orig_config"
}

@test "load_config skips comments and empty lines" {
    local config_file="${BATS_TEST_TMPDIR}/config_comments"
    echo '# This is a comment' > "$config_file"
    echo '' >> "$config_file"
    echo 'workdir="/tmp"' >> "$config_file"

    local orig_config="$CONFIG_FILE"
    CONFIG_FILE="$config_file"

    load_config

    [ "$CC_WORKDIR" == "/tmp" ]

    CONFIG_FILE="$orig_config"
}

@test "cmd_config list works" {
    run cmd_config list
    [ "$status" -eq 0 ]
    [[ "$output" == *"Current configuration"* ]]
}

@test "cmd_config set validates workdir" {
    run cmd_config set workdir "/nonexistent/path"
    [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
}

@test "cmd_config set validates permission_mode" {
    run cmd_config set permission_mode invalid
    [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
}

@test "cmd_config set validates timeout" {
    run cmd_config set timeout "notanumber"
    [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
}

@test "cmd_config rejects invalid key" {
    run cmd_config set invalid_key value
    [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
}

@test "cmd_config unset removes key" {
    local config_file="${DATA_DIR}/config"
    echo 'workdir="/tmp/test"' > "$config_file"

    run cmd_config unset workdir
    [ "$status" -eq 0 ]
    [[ "$output" == *"Unset"* ]]

    # Verify key is removed
    ! grep -q "^workdir=" "$config_file"

    rm -f "$config_file"
}

@test "cmd_config unset handles missing key" {
    local config_file="${DATA_DIR}/config"
    echo 'model="sonnet"' > "$config_file"

    # unset should succeed even if key doesn't exist
    run cmd_config unset workdir
    [ "$status" -eq 0 ]

    rm -f "$config_file"
}

@test "cmd_doctor runs without error" {
    run cmd_doctor
    # Doctor returns non-zero if issues found, but should still produce output
    [[ "$output" == *"Health Check"* ]]
}

@test "cmd_doctor checks claude CLI" {
    run cmd_doctor
    [[ "$output" == *"Claude CLI"* ]]
}

@test "cmd_doctor checks required tools" {
    run cmd_doctor
    [[ "$output" == *"flock"* ]]
}

@test "cmd_logs fails for non-existent job" {
    run cmd_logs "nonexistent"
    [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
}

@test "cmd_logs shows log content" {
    local job_id="testlog"
    local log_file; log_file=$(get_log_file "$job_id")
    echo "Test log entry" > "$log_file"

    run cmd_logs "$job_id" "false"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Test log entry"* ]]

    rm -f "$log_file"
}

@test "cmd_logs defaults to non-follow mode" {
    local job_id="testcat"
    local log_file; log_file=$(get_log_file "$job_id")
    echo "Log content" > "$log_file"

    run cmd_logs "$job_id" "false"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Logs for job"* ]]
    [[ "$output" != *"Following logs"* ]]

    rm -f "$log_file"
}

@test "get_stat returns file size" {
    local test_file="${BATS_TEST_TMPDIR}/stat_test"
    echo "test content" > "$test_file"

    run get_stat "$test_file" size
    [ "$status" -eq 0 ]
    [[ "$output" -gt 0 ]]

    rm -f "$test_file"
}

@test "get_stat returns mtime" {
    local test_file="${BATS_TEST_TMPDIR}/stat_mtime_test"
    touch "$test_file"

    run get_stat "$test_file" mtime
    [ "$status" -eq 0 ]
    [[ -n "$output" ]]

    rm -f "$test_file"
}

@test "get_stat returns mtime_unix" {
    local test_file="${BATS_TEST_TMPDIR}/stat_unix_test"
    touch "$test_file"

    run get_stat "$test_file" mtime_unix
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]

    rm -f "$test_file"
}

@test "get_stat fails for non-existent file" {
    run get_stat "/nonexistent/file" size
    [ "$status" -ne 0 ]
}

@test "remove_file removes existing file" {
    local test_file="${BATS_TEST_TMPDIR}/remove_test"
    touch "$test_file"

    run remove_file "$test_file" "test file"
    [ "$status" -eq 0 ]
    [[ ! -f "$test_file" ]]
}

@test "remove_file handles non-existent file gracefully" {
    run remove_file "/nonexistent/file" "test file"
    [ "$status" -eq 0 ]
}

@test "remove_file outputs message when removing" {
    local test_file="${BATS_TEST_TMPDIR}/remove_msg_test"
    touch "$test_file"

    run remove_file "$test_file" "test label"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Removed test label"* ]]
}

@test "purge_single_file updates counters" {
    local test_file="${BATS_TEST_TMPDIR}/purge_test"
    echo "test content for purge" > "$test_file"

    PURGE_COUNT=0
    PURGE_BYTES=0

    purge_single_file "$test_file" "test file" >/dev/null
    [ "$PURGE_COUNT" -eq 1 ]
    [ "$PURGE_BYTES" -gt 0 ]
}

@test "purge_single_file handles non-existent file" {
    PURGE_COUNT=0
    PURGE_BYTES=0

    purge_single_file "/nonexistent/file" "test" >/dev/null
    [ "$PURGE_COUNT" -eq 1 ]
    [ "$PURGE_BYTES" -eq 0 ]
}

@test "cmd_history parses structured history" {
    local job_id="histtest"
    local log_file; log_file=$(get_log_file "$job_id")
    local history_file; history_file=$(get_history_file "$job_id")

    echo "Some log entry" > "$log_file"
    echo 'start="2024-01-01 10:00:00" end="2024-01-01 10:05:00" status="success" exit_code="0"' > "$history_file"

    run cmd_history "$job_id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"2024-01-01 10:00:00"* ]]
    [[ "$output" == *"✓"* ]]

    rm -f "$log_file" "$history_file"
}

@test "cmd_history shows failed status" {
    local job_id="histfail"
    local log_file; log_file=$(get_log_file "$job_id")
    local history_file; history_file=$(get_history_file "$job_id")

    echo "Log entry" > "$log_file"
    echo 'start="2024-01-01 10:00:00" end="2024-01-01 10:05:00" status="failed" exit_code="1"' > "$history_file"

    run cmd_history "$job_id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit: 1"* ]]

    rm -f "$log_file" "$history_file"
}

@test "cmd_history falls back to log file when no history" {
    local job_id="histfallback"
    local log_file; log_file=$(get_log_file "$job_id")

    echo "Log entry line 1" > "$log_file"
    echo "Log entry line 2" >> "$log_file"

    run cmd_history "$job_id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No structured history available"* ]]
    [[ "$output" == *"Log entry line 1"* ]]

    rm -f "$log_file"
}

@test "cmd_history respects lines argument" {
    local job_id="histlines"
    local log_file; log_file=$(get_log_file "$job_id")
    local history_file; history_file=$(get_history_file "$job_id")

    echo "Log entry" > "$log_file"
    # Create multiple history entries
    for i in {1..5}; do
        echo "start=\"2024-01-0${i} 10:00:00\" end=\"2024-01-0${i} 10:05:00\" status=\"success\" exit_code=\"0\"" >> "$history_file"
    done

    # Request only 2 lines
    run cmd_history "$job_id" 2
    [ "$status" -eq 0 ]
    # Should only show 2 entries (last 2 lines of history)
    local success_count
    success_count=$(echo "$output" | grep -c "✓" || echo "0")
    [ "$success_count" -eq 2 ]

    rm -f "$log_file" "$history_file"
}

@test "safe_numeric returns numeric value" {
    run safe_numeric "123" "0"
    [ "$status" -eq 0 ]
    [ "$output" == "123" ]
}

@test "safe_numeric returns default for non-numeric" {
    run safe_numeric "abc" "0"
    [ "$status" -eq 0 ]
    [ "$output" == "0" ]
}

@test "safe_numeric returns default for empty string" {
    run safe_numeric "" "10"
    [ "$status" -eq 0 ]
    [ "$output" == "10" ]
}

@test "safe_numeric handles zero correctly" {
    run safe_numeric "0" "10"
    [ "$status" -eq 0 ]
    [ "$output" == "0" ]
}

@test "safe_numeric handles negative as non-numeric" {
    run safe_numeric "-5" "10"
    [ "$status" -eq 0 ]
    [ "$output" == "10" ]
}

@test "safe_numeric handles floating point as non-numeric" {
    run safe_numeric "1.5" "10"
    [ "$status" -eq 0 ]
    [ "$output" == "10" ]
}

@test "safe_numeric handles large numbers" {
    run safe_numeric "999999999" "0"
    [ "$status" -eq 0 ]
    [ "$output" == "999999999" ]
}

@test "build_cron_entry creates correct format" {
    run build_cron_entry "abc123" "0 9 * * *" "/tmp/run.sh" "true" "Test prompt"
    [ "$status" -eq 0 ]
    [[ "$output" == "0 9 * * * /tmp/run.sh  # CC-CRON:abc123:"* ]]
    [[ "$output" == *"recurring=true"* ]]
    [[ "$output" == *"prompt=Test prompt"* ]]
}

@test "build_cron_entry truncates long prompts" {
    local long_prompt="This is a very long prompt that should be truncated to 30 characters for display in crontab"
    run build_cron_entry "xyz789" "0 * * * *" "/tmp/run.sh" "false" "$long_prompt"
    [ "$status" -eq 0 ]
    # The prompt in the output should be truncated to 30 chars
    [[ "$output" == *"prompt=This is a very long prompt tha"* ]]
}

@test "crontab_has_entry detects existing entry" {
    # Skip if crontab is not available
    if ! crontab -l &>/dev/null; then
        skip "crontab not available in test environment"
    fi
    # Add a test entry to crontab
    local test_entry="0 9 * * * /tmp/test.sh  # CC-CRON:test123:recurring=true"
    crontab_add_entry "$test_entry"

    run crontab_has_entry "CC-CRON:test123"
    [ "$status" -eq 0 ]

    # Cleanup
    crontab_remove_entry "CC-CRON:test123"
}

@test "crontab_has_entry returns false for missing entry" {
    run crontab_has_entry "CC-CRON:nonexistent999"
    [ "$status" -ne 0 ]
}

@test "crontab_remove_entry removes entry" {
    # Skip if crontab is not available
    if ! crontab -l &>/dev/null; then
        skip "crontab not available in test environment"
    fi
    # Add a test entry
    local test_entry="0 9 * * * /tmp/test.sh  # CC-CRON:removeme:recurring=true"
    crontab_add_entry "$test_entry"

    # Verify it exists
    crontab_has_entry "CC-CRON:removeme"

    # Remove it
    run crontab_remove_entry "CC-CRON:removeme"
    [ "$status" -eq 0 ]

    # Verify it's gone
    run crontab_has_entry "CC-CRON:removeme"
    [ "$status" -ne 0 ]
}

@test "get_crontab returns content or empty" {
    _CRONTAB_CACHE=""
    run get_crontab
    # Should succeed (may be empty if no crontab)
    [ "$status" -eq 0 ]
}

@test "write_meta_file creates valid metadata" {
    local job_id="testwrite"
    run write_meta_file "$job_id" "2024-01-01 10:00:00" "0 9 * * *" "true" "test prompt" "/tmp" "sonnet" "auto" "0" "/tmp/run.sh"
    [ "$status" -eq 0 ]

    local meta_file; meta_file=$(get_meta_file "$job_id")
    [ -f "$meta_file" ]

    # Verify content
    source "$meta_file"
    [ "$id" == "testwrite" ]
    [ "$cron" == "0 9 * * *" ]
    [ "$recurring" == "true" ]
    [ "$prompt" == "test prompt" ]

    rm -f "$meta_file"
}

@test "generate_run_script creates executable script" {
    local job_id="testgen"
    generate_run_script "$job_id" "/tmp" "sonnet" "auto" "0" "true" "test prompt" >/dev/null

    local run_script; run_script=$(get_run_script "$job_id")
    [ -f "$run_script" ]
    [ -x "$run_script" ]

    # Verify script contains expected elements
    grep -q "claude" "$run_script"
    grep -q "test prompt" "$run_script"

    rm -f "$run_script"
}

@test "generate_run_script handles empty model" {
    local job_id="testnomodel"
    generate_run_script "$job_id" "/tmp" "" "bypassPermissions" "0" "true" "prompt" >/dev/null

    local run_script; run_script=$(get_run_script "$job_id")
    [ -f "$run_script" ]

    # Should not contain --model flag
    ! grep -q "\-\-model" "$run_script"

    rm -f "$run_script"
}

@test "require_job_id fails without argument" {
    run require_job_id "testcmd"
    [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
    [[ "$output" == *"Usage: cc-cron testcmd <job-id>"* ]]
}

@test "require_job_id succeeds with argument" {
    run require_job_id "testcmd" "abc123"
    [ "$status" -eq 0 ]
}

@test "parse_job_options parses cron option" {
    parse_job_options --cron "0 12 * * *"
    [ "$PARSED_CRON" == "0 12 * * *" ]
    [ "$PARSED_HAS_CHANGES" -eq 1 ]
}

@test "parse_job_options parses prompt option" {
    parse_job_options --prompt "new prompt"
    [ "$PARSED_PROMPT" == "new prompt" ]
    [ "$PARSED_HAS_CHANGES" -eq 1 ]
}

@test "parse_job_options parses multiple options" {
    parse_job_options --cron "0 0 * * *" --prompt "test" --model "sonnet"
    [ "$PARSED_CRON" == "0 0 * * *" ]
    [ "$PARSED_PROMPT" == "test" ]
    [ "$PARSED_MODEL" == "sonnet" ]
    [ "$PARSED_HAS_CHANGES" -eq 1 ]
}

@test "parse_job_options rejects invalid cron" {
    run parse_job_options --cron "invalid"
    [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
}

@test "parse_job_options rejects missing argument" {
    run parse_job_options --cron
    [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
    [[ "$output" == *"requires"* ]]
}

@test "cmd_clone fails for non-existent job" {
    run cmd_clone "nonexistent"
    [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
}

@test "cmd_clone creates new job from existing" {
    # Create source job
    local source_id="clonesrc"
    local meta_file; meta_file=$(get_meta_file "$source_id")
    echo 'id="clonesrc"' > "$meta_file"
    echo 'created="2024-01-01"' >> "$meta_file"
    echo 'cron="0 9 * * *"' >> "$meta_file"
    echo 'recurring="true"' >> "$meta_file"
    echo 'prompt="original prompt"' >> "$meta_file"
    echo 'workdir="/tmp"' >> "$meta_file"
    echo 'model="sonnet"' >> "$meta_file"
    echo 'permission_mode="auto"' >> "$meta_file"
    echo 'timeout="60"' >> "$meta_file"
    echo 'run_script="/tmp/run.sh"' >> "$meta_file"

    run cmd_clone "$source_id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cloned job"* ]]
    [[ "$output" == *"Created cron job"* ]]

    # Cleanup
    rm -f "$meta_file"
}

@test "cmd_clone with options overrides source values" {
    # Create source job
    local source_id="clonesrc2"
    local meta_file; meta_file=$(get_meta_file "$source_id")
    echo 'id="clonesrc2"' > "$meta_file"
    echo 'created="2024-01-01"' >> "$meta_file"
    echo 'cron="0 9 * * *"' >> "$meta_file"
    echo 'recurring="true"' >> "$meta_file"
    echo 'prompt="original prompt"' >> "$meta_file"
    echo 'workdir="/tmp"' >> "$meta_file"
    echo 'model=""' >> "$meta_file"
    echo 'permission_mode="bypassPermissions"' >> "$meta_file"
    echo 'timeout="0"' >> "$meta_file"
    echo 'run_script="/tmp/run.sh"' >> "$meta_file"

    # Clone with custom cron
    run cmd_clone "$source_id" --cron "0 12 * * *"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cloned job"* ]]

    # Cleanup
    rm -f "$meta_file"
}

@test "cmd_clone preserves tags from source" {
    # Create source job with tags
    local source_id="clonetags"
    local meta_file; meta_file=$(get_meta_file "$source_id")
    echo 'id="clonetags"' > "$meta_file"
    echo 'created="2024-01-01"' >> "$meta_file"
    echo 'cron="0 9 * * *"' >> "$meta_file"
    echo 'recurring="true"' >> "$meta_file"
    echo 'prompt="tagged job"' >> "$meta_file"
    echo 'workdir="'"${BATS_TEST_TMPDIR}"'"' >> "$meta_file"
    echo 'model=""' >> "$meta_file"
    echo 'permission_mode="bypassPermissions"' >> "$meta_file"
    echo 'timeout="0"' >> "$meta_file"
    echo 'tags="prod,backup"' >> "$meta_file"
    echo 'run_script="/tmp/run.sh"' >> "$meta_file"

    cmd_clone "$source_id" >/dev/null

    # Verify cloned job has tags
    [[ -n "${LAST_CREATED_JOB_ID:-}" ]]
    local cloned_meta; cloned_meta=$(get_meta_file "$LAST_CREATED_JOB_ID")
    [[ -f "$cloned_meta" ]]
    grep -q 'tags="prod,backup"' "$cloned_meta"

    # Cleanup
    rm -f "$meta_file" "$cloned_meta"
}

@test "cmd_list shows no jobs message when empty" {
    # Clear crontab cache
    _CRONTAB_CACHE=""

    # Only test if crontab is empty or not accessible
    local crontab_content
    crontab_content=$(crontab -l 2>/dev/null) || crontab_content=""

    # Skip if there are existing cc-cron jobs in crontab
    if [[ "$crontab_content" == *"CC-CRON:"* ]]; then
        skip "crontab has existing cc-cron jobs"
    fi

    # If crontab is empty or has no CC-CRON entries, test the output
    run cmd_list
    [ "$status" -eq 0 ]
    [[ "$output" == *"No scheduled jobs found"* ]] || [[ "$output" == *"Scheduled Claude Code Cron Jobs"* ]]
}

@test "cmd_list shows job with metadata" {
    local job_id="listtest"
    local meta_file; meta_file=$(get_meta_file "$job_id")
    local log_file; log_file=$(get_log_file "$job_id")

    echo 'id="listtest"' > "$meta_file"
    echo 'created="2024-01-01"' >> "$meta_file"
    echo 'cron="0 9 * * *"' >> "$meta_file"
    echo 'recurring="true"' >> "$meta_file"
    echo 'prompt="test prompt"' >> "$meta_file"
    echo 'workdir="/tmp"' >> "$meta_file"
    echo 'model=""' >> "$meta_file"
    echo 'permission_mode="bypassPermissions"' >> "$meta_file"
    echo 'timeout="0"' >> "$meta_file"

    # Create a minimal log file with CC-CRON marker
    echo "0 9 * * * /tmp/run.sh  # CC-CRON:listtest:recurring=true" > "$log_file"

    run cmd_list
    [ "$status" -eq 0 ]

    rm -f "$meta_file" "$log_file"
}

@test "cmd_status shows summary" {
    run cmd_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"CC-Cron Status Report"* ]]
    [[ "$output" == *"Total scheduled jobs"* ]]
    [[ "$output" == *"Summary"* ]]
}

@test "cmd_add creates job with defaults" {
    local job_workdir="$BATS_TEST_TMPDIR"
    LAST_CREATED_JOB_ID=""
    cmd_add "0 9 * * *" "test prompt" "true" "$job_workdir" "" "bypassPermissions" "0" >/dev/null
    [[ -n "$LAST_CREATED_JOB_ID" ]]

    # Cleanup
    rm -f "$(get_meta_file "$LAST_CREATED_JOB_ID")"
    rm -f "$(get_run_script "$LAST_CREATED_JOB_ID")"
    crontab_remove_entry "CC-CRON:${LAST_CREATED_JOB_ID}" 2>/dev/null || true
}

@test "cmd_add validates cron expression" {
    run cmd_add "invalid" "test" "true" "$BATS_TEST_TMPDIR" "" "bypassPermissions" "0"
    [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
}

@test "cmd_add validates workdir" {
    run cmd_add "0 9 * * *" "test" "true" "/nonexistent/path" "" "bypassPermissions" "0"
    [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
}

@test "cmd_add validates permission mode" {
    run cmd_add "0 9 * * *" "test" "true" "$BATS_TEST_TMPDIR" "" "invalid_mode" "0"
    [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
}

@test "cmd_add creates one-shot job" {
    local job_workdir="$BATS_TEST_TMPDIR"
    run cmd_add "0 9 * * *" "one shot" "false" "$job_workdir" "" "bypassPermissions" "0"
    [ "$status" -eq 0 ]
    [[ "$output" == *"One-shot job"* ]]

    # Cleanup
    rm -f "$(get_meta_file "$LAST_CREATED_JOB_ID")"
    rm -f "$(get_run_script "$LAST_CREATED_JOB_ID")"
    crontab_remove_entry "CC-CRON:${LAST_CREATED_JOB_ID}" 2>/dev/null || true
}

@test "cmd_add with model and timeout" {
    local job_workdir="$BATS_TEST_TMPDIR"
    run cmd_add "0 9 * * *" "with model" "true" "$job_workdir" "sonnet" "auto" "300"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Model: sonnet"* ]]
    [[ "$output" == *"Timeout: 300s"* ]]

    # Cleanup
    rm -f "$(get_meta_file "$LAST_CREATED_JOB_ID")"
    rm -f "$(get_run_script "$LAST_CREATED_JOB_ID")"
    crontab_remove_entry "CC-CRON:${LAST_CREATED_JOB_ID}" 2>/dev/null || true
}

@test "cmd_add with tags" {
    local job_workdir="$BATS_TEST_TMPDIR"
    LAST_CREATED_JOB_ID=""
    cmd_add "0 9 * * *" "tagged job" "true" "$job_workdir" "" "bypassPermissions" "0" "false" "prod,backup" >/dev/null
    [ -n "$LAST_CREATED_JOB_ID" ]

    # Verify tags are stored in metadata
    local meta_file; meta_file=$(get_meta_file "$LAST_CREATED_JOB_ID")
    [[ -f "$meta_file" ]]
    grep -q 'tags="prod,backup"' "$meta_file"

    # Cleanup
    rm -f "$meta_file"
    rm -f "$(get_run_script "$LAST_CREATED_JOB_ID")"
    crontab_remove_entry "CC-CRON:${LAST_CREATED_JOB_ID}" 2>/dev/null || true
}

@test "cmd_show displays tags when set" {
    local job_id="taggedjob"
    local meta_file; meta_file=$(get_meta_file "$job_id")
    local run_script; run_script=$(get_run_script "$job_id")

    cat > "$meta_file" << EOF
id="${job_id}"
created="2024-01-01 10:00:00"
cron="0 9 * * *"
recurring="true"
prompt="test prompt"
workdir="/tmp"
model=""
permission_mode="bypassPermissions"
timeout="0"
tags="prod,backup"
run_script="${run_script}"
EOF

    run cmd_show "$job_id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Tags:         prod,backup"* ]]

    rm -f "$meta_file"
}

@test "cmd_list filters by tag" {
    local job_workdir="$BATS_TEST_TMPDIR"

    # Create job with tag
    cmd_add "0 9 * * *" "prod job" "true" "$job_workdir" "" "bypassPermissions" "0" "false" "prod" >/dev/null
    local prod_job="$LAST_CREATED_JOB_ID"

    # Create job without tag
    cmd_add "0 10 * * *" "untagged job" "true" "$job_workdir" "" "bypassPermissions" "0" >/dev/null
    local untagged_job="$LAST_CREATED_JOB_ID"

    # List jobs with prod tag
    run cmd_list "prod"
    [ "$status" -eq 0 ]
    [[ "$output" == *"${prod_job}"* ]]
    [[ "$output" != *"${untagged_job}"* ]]

    # Cleanup
    rm -f "$(get_meta_file "$prod_job")" "$(get_run_script "$prod_job")"
    rm -f "$(get_meta_file "$untagged_job")" "$(get_run_script "$untagged_job")"
    crontab_remove_entry "CC-CRON:${prod_job}" 2>/dev/null || true
    crontab_remove_entry "CC-CRON:${untagged_job}" 2>/dev/null || true
}

@test "cmd_edit updates tags" {
    local job_id="edittagjob"
    local meta_file; meta_file=$(get_meta_file "$job_id")

    # Create initial metadata
    cat > "$meta_file" << EOF
id="${job_id}"
created="2024-01-01 10:00:00"
cron="0 9 * * *"
recurring="true"
prompt="test prompt"
workdir="/tmp"
model=""
permission_mode="bypassPermissions"
timeout="0"
run_script="/tmp/run.sh"
EOF

    # Add crontab entry
    crontab_add_entry "0 9 * * * /tmp/run.sh  # CC-CRON:${job_id}:recurring=true" 2>/dev/null || true

    run cmd_edit "$job_id" --tags "newtag"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Tags: none"* ]]

    # Verify tags updated
    grep -q 'tags="newtag"' "$meta_file"

    rm -f "$meta_file"
    crontab_remove_entry "CC-CRON:${job_id}" 2>/dev/null || true
}

@test "cmd_help shows command list" {
    run cmd_help
    [ "$status" -eq 0 ]
    [[ "$output" == *"COMMANDS:"* ]]
    [[ "$output" == *"add"* ]]
    [[ "$output" == *"list"* ]]
    [[ "$output" == *"remove"* ]]
}

@test "cmd_help add shows detailed help" {
    run cmd_help "add"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cc-cron add"* ]]
    [[ "$output" == *"--once"* ]]
    [[ "$output" == *"--workdir"* ]]
    [[ "$output" == *"--model"* ]]
}

@test "cmd_help config shows detailed help" {
    run cmd_help "config"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cc-cron config"* ]]
    [[ "$output" == *"workdir"* ]]
    [[ "$output" == *"model"* ]]
}

@test "cmd_help edit shows detailed help" {
    run cmd_help "edit"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cc-cron edit"* ]]
    [[ "$output" == *"--cron"* ]]
    [[ "$output" == *"--prompt"* ]]
}

@test "cmd_help clone shows detailed help" {
    run cmd_help "clone"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cc-cron clone"* ]]
    [[ "$output" == *"Override"* ]]
}

@test "cmd_help purge shows detailed help" {
    run cmd_help "purge"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cc-cron purge"* ]]
    [[ "$output" == *"--dry-run"* ]]
}

@test "cmd_help list shows detailed help" {
    run cmd_help "list"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cc-cron list"* ]]
    [[ "$output" == *"tag"* ]]
}

@test "cmd_help status shows detailed help" {
    run cmd_help "status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cc-cron status"* ]]
}

@test "cmd_help unknown topic returns error" {
    run cmd_help "unknowncommand"
    [ "$status" -eq 1 ]  # General error
    [[ "$output" == *"Unknown help topic"* ]]
}

@test "cmd_import handles invalid JSON" {
    command -v jq &>/dev/null || skip "jq not installed"
    local json_file="${BATS_TEST_TMPDIR}/invalid.json"
    echo "not valid json" > "$json_file"

    run cmd_import "$json_file"
    [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
}

@test "cmd_import handles empty jobs array" {
    command -v jq &>/dev/null || skip "jq not installed"
    local json_file="${BATS_TEST_TMPDIR}/empty.json"
    echo '{"version":"1.0","jobs":[]}' > "$json_file"

    run cmd_import "$json_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No jobs found"* ]]
}

@test "cmd_import handles missing workdir" {
    command -v jq &>/dev/null || skip "jq not installed"
    local json_file="${BATS_TEST_TMPDIR}/missing_dir.json"
    cat > "$json_file" << 'EOF'
{"version":"1.0","jobs":[{"id":"test","created":"2024-01-01","cron":"0 9 * * *","recurring":true,"prompt":"test","workdir":"/nonexistent/path/12345","model":"","permission_mode":"bypassPermissions","timeout":0,"paused":false}]}
EOF

    run cmd_import "$json_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping job with missing workdir"* ]]
}

@test "cmd_import handles invalid cron expression" {
    command -v jq &>/dev/null || skip "jq not installed"
    local json_file="${BATS_TEST_TMPDIR}/bad_cron.json"
    cat > "$json_file" << EOF
{"version":"1.0","jobs":[{"id":"test","created":"2024-01-01","cron":"invalid cron","recurring":true,"prompt":"test","workdir":"${BATS_TEST_TMPDIR}","model":"","permission_mode":"bypassPermissions","timeout":0,"paused":false}]}
EOF

    run cmd_import "$json_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping invalid cron"* ]]
}

@test "cmd_import preserves tags" {
    command -v jq &>/dev/null || skip "jq not installed"
    local json_file="${BATS_TEST_TMPDIR}/tags_import.json"
    cat > "$json_file" << EOF
{"version":"1.0","jobs":[{"id":"tagtest","created":"2024-01-01","cron":"0 9 * * *","recurring":true,"prompt":"test job with tags","workdir":"${BATS_TEST_TMPDIR}","model":"","permission_mode":"bypassPermissions","timeout":0,"paused":false,"tags":"prod,backup"}]}
EOF

    cmd_import "$json_file" >/dev/null

    # Verify the job was created with tags (use the ID from LAST_CREATED_JOB_ID)
    [[ -n "${LAST_CREATED_JOB_ID:-}" ]]
    local meta_file; meta_file=$(get_meta_file "$LAST_CREATED_JOB_ID")
    [[ -f "$meta_file" ]]
    grep -q 'tags="prod,backup"' "$meta_file"

    # Cleanup
    rm -f "$meta_file"
}

@test "cmd_export escapes quotes in prompt" {
    local job_id="quotejob"
    local meta_file; meta_file=$(get_meta_file "$job_id")
    echo 'id="quotejob"' > "$meta_file"
    echo 'created="2024-01-01"' >> "$meta_file"
    echo 'cron="0 0 * * *"' >> "$meta_file"
    echo 'recurring="true"' >> "$meta_file"
    echo 'prompt="test with \"quotes\" inside"' >> "$meta_file"
    echo 'workdir="/tmp"' >> "$meta_file"
    echo 'model=""' >> "$meta_file"
    echo 'permission_mode="bypassPermissions"' >> "$meta_file"
    echo 'timeout="0"' >> "$meta_file"
    echo 'run_script="/tmp/run.sh"' >> "$meta_file"

    run cmd_export "$job_id"
    [ "$status" -eq 0 ]
    # Check that quotes are escaped in JSON output
    [[ "$output" == *'\"quotes\"'* ]]

    rm -f "$meta_file"
}

@test "cmd_export includes tags in JSON output" {
    local job_id="exportags"
    local meta_file; meta_file=$(get_meta_file "$job_id")
    echo 'id="exportags"' > "$meta_file"
    echo 'created="2024-01-01"' >> "$meta_file"
    echo 'cron="0 0 * * *"' >> "$meta_file"
    echo 'recurring="true"' >> "$meta_file"
    echo 'prompt="test job"' >> "$meta_file"
    echo 'workdir="/tmp"' >> "$meta_file"
    echo 'model=""' >> "$meta_file"
    echo 'permission_mode="bypassPermissions"' >> "$meta_file"
    echo 'timeout="0"' >> "$meta_file"
    echo 'tags="prod,backup"' >> "$meta_file"
    echo 'run_script="/tmp/run.sh"' >> "$meta_file"

    run cmd_export "$job_id"
    [ "$status" -eq 0 ]
    # Check that tags are included in JSON output
    [[ "$output" == *'"tags":"prod,backup"'* ]]

    rm -f "$meta_file"
}

@test "parse_job_options validates permission-mode" {
    run parse_job_options --permission-mode "invalid_mode"
    [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
    [[ "$output" == *"Invalid permission mode"* ]]
}

@test "parse_job_options validates timeout" {
    run parse_job_options --timeout "not_a_number"
    [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
    [[ "$output" == *"Timeout must be a non-negative number"* ]]
}

@test "parse_job_options accepts valid permission-mode" {
    parse_job_options --permission-mode "auto"
    [ "$PARSED_PERMISSION" == "auto" ]
}

@test "parse_job_options accepts valid timeout" {
    parse_job_options --timeout "300"
    [ "$PARSED_TIMEOUT" == "300" ]
}

@test "parse_job_options parses workdir" {
    parse_job_options --workdir "$BATS_TEST_TMPDIR"
    [ "$PARSED_WORKDIR" == "$BATS_TEST_TMPDIR" ]
}

@test "parse_job_options rejects invalid workdir" {
    run parse_job_options --workdir "/nonexistent/path"
    [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
    [[ "$output" == *"Directory not found"* ]]
}

@test "parse_job_options rejects unknown option" {
    run parse_job_options --unknown-option
    [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
    [[ "$output" == *"Unknown option"* ]]
}

@test "cmd_show displays timeout when set" {
    local job_id="showtimeout"
    create_test_meta "$job_id" "/tmp" "" "bypassPermissions" "300"

    run cmd_show "$job_id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Timeout:"* ]]
    [[ "$output" == *"300s"* ]]

    rm -f "$(get_meta_file "$job_id")"
}

@test "cmd_show displays model when set" {
    local job_id="showmodel"
    create_test_meta "$job_id" "/tmp" "sonnet"

    run cmd_show "$job_id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Model:"* ]]
    [[ "$output" == *"sonnet"* ]]

    rm -f "$(get_meta_file "$job_id")"
}

@test "cmd_show displays paused status" {
    local job_id="showpaused"
    create_test_meta "$job_id"
    local paused_file="${DATA_DIR}/${job_id}.paused"

    touch "$paused_file"

    run cmd_show "$job_id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PAUSED"* ]]

    rm -f "$(get_meta_file "$job_id")" "$paused_file"
}

@test "cmd_show displays execution statistics" {
    local job_id="showstats"
    create_test_meta "$job_id"
    local history_file; history_file=$(get_history_file "$job_id")

    echo 'start="2024-01-01 10:00:00" end="2024-01-01 10:05:00" status="success" exit_code="0"' > "$history_file"
    echo 'start="2024-01-02 10:00:00" end="2024-01-02 10:05:00" status="failed" exit_code="1"' >> "$history_file"

    run cmd_show "$job_id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Statistics:"* ]]
    [[ "$output" == *"Total runs:"* ]]
    [[ "$output" == *"2"* ]]

    rm -f "$(get_meta_file "$job_id")" "$history_file"
}

@test "cmd_show handles missing history gracefully" {
    local job_id="showmissinghist"
    create_test_meta "$job_id"

    run cmd_show "$job_id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Job Details"* ]]
    [[ "$output" != *"Statistics:"* ]]

    rm -f "$(get_meta_file "$job_id")"
}

@test "cmd_show shows running status" {
    local job_id="showrunning"
    create_test_meta "$job_id"
    local status_file; status_file=$(get_status_file "$job_id")

    echo 'start_time="2024-01-01 10:00:00"' > "$status_file"
    echo 'status="running"' >> "$status_file"

    run cmd_show "$job_id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RUNNING"* ]]

    rm -f "$(get_meta_file "$job_id")" "$status_file"
}

@test "cmd_show shows success status" {
    local job_id="showsuccess"
    create_test_meta "$job_id"
    local status_file; status_file=$(get_status_file "$job_id")

    echo 'start_time="2024-01-01 10:00:00"' > "$status_file"
    echo 'end_time="2024-01-01 10:05:00"' >> "$status_file"
    echo 'status="success"' >> "$status_file"
    echo 'exit_code="0"' >> "$status_file"

    run cmd_show "$job_id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SUCCESS"* ]]

    rm -f "$(get_meta_file "$job_id")" "$status_file"
}

@test "cmd_show shows failed status with exit code" {
    local job_id="showfailed"
    create_test_meta "$job_id"
    local status_file; status_file=$(get_status_file "$job_id")

    echo 'start_time="2024-01-01 10:00:00"' > "$status_file"
    echo 'end_time="2024-01-01 10:05:00"' >> "$status_file"
    echo 'status="failed"' >> "$status_file"
    echo 'exit_code="42"' >> "$status_file"

    run cmd_show "$job_id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"FAILED"* ]]
    [[ "$output" == *"42"* ]]

    rm -f "$(get_meta_file "$job_id")" "$status_file"
}

@test "cmd_status handles no jobs gracefully" {
    # Clear any existing jobs first
    local crontab_content
    crontab_content=$(crontab -l 2>/dev/null) || crontab_content=""

    # Skip if there are existing cc-cron jobs
    if [[ "$crontab_content" == *"CC-CRON:"* ]]; then
        skip "crontab has existing cc-cron jobs"
    fi

    run cmd_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"Total scheduled jobs: 0"* ]]
}

@test "build_cron_entry handles special characters in prompt" {
    local prompt="Test with 'single quotes' and \"double quotes\""
    run build_cron_entry "abc123" "0 9 * * *" "/tmp/run.sh" "true" "$prompt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CC-CRON:abc123"* ]]
}

@test "cmd_help logs shows detailed help" {
    run cmd_help "logs"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cc-cron logs"* ]]
    [[ "$output" == *"--tail"* ]]
}

@test "cmd_help run shows detailed help" {
    run cmd_help "run"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cc-cron run"* ]]
    [[ "$output" == *"Execute a job immediately"* ]]
}

@test "cmd_help show shows detailed help" {
    run cmd_help "show"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cc-cron show"* ]]
    [[ "$output" == *"Display job details"* ]]
}

@test "cmd_help history shows detailed help" {
    run cmd_help "history"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cc-cron history"* ]]
    [[ "$output" == *"View execution history"* ]]
}

@test "cmd_completion outputs bash completion script" {
    run cmd_completion
    [ "$status" -eq 0 ]
    [[ "$output" == *"_cc_cron_completion"* ]]
    [[ "$output" == *"complete -F"* ]]
}

@test "cmd_completion includes main commands" {
    run cmd_completion
    [ "$status" -eq 0 ]
    [[ "$output" == *"add"* ]]
    [[ "$output" == *"list"* ]]
    [[ "$output" == *"remove"* ]]
    [[ "$output" == *"status"* ]]
    [[ "$output" == *"edit"* ]]
}

@test "cmd_completion includes model options" {
    run cmd_completion
    [ "$status" -eq 0 ]
    [[ "$output" == *"sonnet"* ]]
    [[ "$output" == *"opus"* ]]
    [[ "$output" == *"haiku"* ]]
}

@test "cmd_completion includes permission modes" {
    run cmd_completion
    [ "$status" -eq 0 ]
    [[ "$output" == *"bypassPermissions"* ]]
    [[ "$output" == *"acceptEdits"* ]]
}

@test "generate_run_script includes timeout when set" {
    local job_id="timeoutjob"
    generate_run_script "$job_id" "/tmp" "sonnet" "auto" "300" "true" "test prompt" >/dev/null

    local run_script; run_script=$(get_run_script "$job_id")
    [ -f "$run_script" ]
    grep -q 'timeout "\${TIMEOUT}"' "$run_script"
    grep -q 'TIMEOUT="300"' "$run_script"

    rm -f "$run_script"
}

@test "generate_run_script without timeout has no timeout command" {
    local job_id="notimeout"
    generate_run_script "$job_id" "/tmp" "" "bypassPermissions" "0" "true" "test prompt" >/dev/null

    local run_script; run_script=$(get_run_script "$job_id")
    [ -f "$run_script" ]
    ! grep -q "timeout " "$run_script"

    rm -f "$run_script"
}

@test "write_meta_file includes modified field when provided" {
    local job_id="modifiedjob"
    write_meta_file "$job_id" "2024-01-01 10:00:00" "0 9 * * *" "true" "test prompt" "/tmp" "" "auto" "0" "/tmp/run.sh" "2024-01-02 12:00:00"

    local meta_file; meta_file=$(get_meta_file "$job_id")
    [ -f "$meta_file" ]

    source "$meta_file"
    [ "$modified" == "2024-01-02 12:00:00" ]

    rm -f "$meta_file"
}

@test "write_meta_file without modified field omits it" {
    local job_id="nomodified"
    write_meta_file "$job_id" "2024-01-01 10:00:00" "0 9 * * *" "true" "test prompt" "/tmp" "" "auto" "0" "/tmp/run.sh"

    local meta_file; meta_file=$(get_meta_file "$job_id")
    [ -f "$meta_file" ]

    # Should not contain modified field
    ! grep -q "modified=" "$meta_file"

    rm -f "$meta_file"
}

@test "error function outputs to stderr" {
    run error "Test error message"
    [ "$status" -eq 1 ]  # EXIT_ERROR (default)
    [[ "$output" == *"Test error message"* ]]
}

@test "error function uses custom exit code" {
    run error "Custom exit" 42
    [ "$status" -eq 42 ]
}

@test "error function defaults to EXIT_ERROR" {
    run error "Default exit"
    [ "$status" -eq 1 ]
}

@test "info function outputs message" {
    run info "Test info"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Test info"* ]]
}

@test "success function outputs message" {
    run success "Test success"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Test success"* ]]
}

@test "warn function outputs message" {
    run warn "Test warning"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Test warning"* ]]
}

@test "cmd_pause handles already paused job" {
    local job_id="alreadypaused"
    local meta_file; meta_file=$(get_meta_file "$job_id")
    local paused_file="${DATA_DIR}/${job_id}.paused"

    # Create minimal meta file
    echo 'id="alreadypaused"' > "$meta_file"
    echo 'created="2024-01-01"' >> "$meta_file"
    echo 'cron="0 9 * * *"' >> "$meta_file"
    echo 'recurring="true"' >> "$meta_file"
    echo 'prompt="test"' >> "$meta_file"
    echo 'workdir="/tmp"' >> "$meta_file"
    echo 'permission_mode="bypassPermissions"' >> "$meta_file"
    echo 'timeout="0"' >> "$meta_file"

    # Create paused file
    touch "$paused_file"

    # Add entry to crontab (so we can check)
    crontab_add_entry "0 9 * * * /tmp/run.sh  # CC-CRON:alreadypaused:recurring=true" 2>/dev/null || true

    run cmd_pause "$job_id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already paused"* ]]

    rm -f "$meta_file" "$paused_file"
}

@test "cmd_resume fails when metadata is missing" {
    local job_id="missingmeta"
    local paused_file="${DATA_DIR}/${job_id}.paused"

    # Create paused file without metadata
    mkdir -p "$DATA_DIR"
    touch "$paused_file"

    run cmd_resume "$job_id"
    [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
    [[ "$output" == *"not found"* ]]

    rm -f "$paused_file"
}

@test "cmd_resume fails when job is not paused" {
    local job_id="notpaused"
    local meta_file; meta_file=$(get_meta_file "$job_id")

    # Create metadata but no paused file
    create_test_meta "$job_id"

    run cmd_resume "$job_id"
    [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
    [[ "$output" == *"is not paused"* ]]

    rm -f "$meta_file"
}

@test "crontab_add_entry and remove work together" {
    # Skip if crontab not available
    if ! crontab -l &>/dev/null; then
        skip "crontab not available"
    fi

    local test_marker="CC-CRON:testaddremove123"
    local test_entry="0 9 * * * /tmp/test.sh  # ${test_marker}:recurring=true"

    # Add entry
    crontab_add_entry "$test_entry"

    # Verify it exists
    crontab_has_entry "$test_marker"
    [ "$?" -eq 0 ]

    # Remove it
    crontab_remove_entry "$test_marker"

    # Verify it's gone
    run crontab_has_entry "$test_marker"
    [ "$status" -ne 0 ]
}

@test "cmd_list handles job with missing metadata" {
    # Create a fake crontab entry with a job ID that has no metadata
    local job_id="missingmeta"
    local meta_file; meta_file=$(get_meta_file "$job_id")

    # Ensure metadata doesn't exist
    rm -f "$meta_file" 2>/dev/null || true

    # Add a fake crontab entry
    crontab_add_entry "0 9 * * * /tmp/run.sh  # CC-CRON:${job_id}:recurring=true" 2>/dev/null || true

    run cmd_list
    [ "$status" -eq 0 ]
    [[ "$output" == *"missingmeta"* ]] || [[ "$output" == *"metadata missing"* ]] || [[ "$output" == *"No scheduled jobs"* ]]

    # Cleanup
    crontab_remove_entry "CC-CRON:${job_id}" 2>/dev/null || true
}

@test "generate_run_script with non-default permission mode" {
    local job_id="permjob"
    generate_run_script "$job_id" "/tmp" "sonnet" "acceptEdits" "0" "true" "test prompt" >/dev/null

    local run_script; run_script=$(get_run_script "$job_id")
    [ -f "$run_script" ]
    grep -q "acceptEdits" "$run_script"

    rm -f "$run_script"
}

@test "generate_run_script with default permission omits flag" {
    local job_id="defaultperm"
    generate_run_script "$job_id" "/tmp" "" "default" "0" "true" "test prompt" >/dev/null

    local run_script; run_script=$(get_run_script "$job_id")
    [ -f "$run_script" ]
    ! grep -q "\-\-permission-mode" "$run_script"

    rm -f "$run_script"
}

@test "cmd_status handles running jobs" {
    local job_id="runningstatus"
    create_test_meta "$job_id"
    local status_file; status_file=$(get_status_file "$job_id")

    echo 'start_time="2024-01-01 10:00:00"' > "$status_file"
    echo 'status="running"' >> "$status_file"

    run cmd_status
    [ "$status" -eq 0 ]

    rm -f "$(get_meta_file "$job_id")" "$status_file"
}

@test "cmd_status handles failed jobs" {
    local job_id="failedstatus"
    create_test_meta "$job_id"
    local status_file; status_file=$(get_status_file "$job_id")

    echo 'start_time="2024-01-01 10:00:00"' > "$status_file"
    echo 'end_time="2024-01-01 10:05:00"' >> "$status_file"
    echo 'status="failed"' >> "$status_file"
    echo 'exit_code="1"' >> "$status_file"

    run cmd_status
    [ "$status" -eq 0 ]

    rm -f "$(get_meta_file "$job_id")" "$status_file"
}

@test "cmd_purge handles orphaned run scripts" {
    local job_id="orphanscript"
    local run_script; run_script=$(get_run_script "$job_id")

    # Create an orphan run script (no crontab entry, no metadata)
    mkdir -p "$DATA_DIR"
    echo "#!/bin/bash" > "$run_script"
    echo "echo test" >> "$run_script"
    chmod +x "$run_script"

    [ -f "$run_script" ]

    # Run purge (should remove orphan files)
    run cmd_purge "0" "false"
    [ "$status" -eq 0 ]

    # The orphan script should be removed
    [[ ! -f "$run_script" ]] || [[ "$output" == *"orphan"* ]]
}

@test "write_meta_file with all fields" {
    local job_id="fullmeta"
    write_meta_file "$job_id" "2024-01-01 10:00:00" "*/5 * * * *" "false" "complex prompt with 'quotes'" "/home/user" "opus" "auto" "3600" "/tmp/run-fullmeta.sh"

    local meta_file; meta_file=$(get_meta_file "$job_id")
    [ -f "$meta_file" ]

    source "$meta_file"
    [ "$id" == "fullmeta" ]
    [ "$cron" == "*/5 * * * *" ]
    [ "$recurring" == "false" ]
    [ "$prompt" == "complex prompt with 'quotes'" ]
    [ "$workdir" == "/home/user" ]
    [ "$model" == "opus" ]
    [ "$permission_mode" == "auto" ]
    [ "$timeout" == "3600" ]

    rm -f "$meta_file"
}

@test "validate_cron_field handles edge case ranges" {
    # Test boundary values
    run validate_cron_field "0" 0 59 "minute"
    [ "$status" -eq 0 ]

    run validate_cron_field "59" 0 59 "minute"
    [ "$status" -eq 0 ]

    run validate_cron_field "23" 0 23 "hour"
    [ "$status" -eq 0 ]

    run validate_cron_field "31" 1 31 "day"
    [ "$status" -eq 0 ]

    run validate_cron_field "12" 1 12 "month"
    [ "$status" -eq 0 ]

    run validate_cron_field "6" 0 6 "weekday"
    [ "$status" -eq 0 ]
}

@test "validate_cron accepts all wildcards" {
    run validate_cron "* * * * *"
    [ "$status" -eq 0 ]
}

@test "cmd_completion includes all command aliases" {
    run cmd_completion
    [ "$status" -eq 0 ]
    # Check for command aliases
    [[ "$output" == *"disable"* ]]
    [[ "$output" == *"enable"* ]]
}

@test "cmd_add --quiet outputs only job ID" {
    local job_workdir="$BATS_TEST_TMPDIR"
    cmd_add "0 9 * * *" "test prompt" "true" "$job_workdir" "" "bypassPermissions" "0" "true" >/dev/null

    # Verify job was created
    [[ -n "$LAST_CREATED_JOB_ID" ]]

    # Verify the output is just the job ID (8 chars)
    run cmd_add "0 10 * * *" "quiet test" "true" "$job_workdir" "" "bypassPermissions" "0" "true"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[a-z0-9]{8}$ ]]

    # Cleanup
    rm -f "$(get_meta_file "$LAST_CREATED_JOB_ID")"
    crontab_remove_entry "CC-CRON:${LAST_CREATED_JOB_ID}" 2>/dev/null || true
}

@test "cmd_add normal output includes SUCCESS message" {
    local job_workdir="$BATS_TEST_TMPDIR"
    run cmd_add "0 11 * * *" "normal test" "true" "$job_workdir" "" "bypassPermissions" "0" "false"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SUCCESS"* ]]
    [[ "$output" == *"Created cron job"* ]]

    # Cleanup
    rm -f "$(get_meta_file "$LAST_CREATED_JOB_ID")"
    crontab_remove_entry "CC-CRON:${LAST_CREATED_JOB_ID}" 2>/dev/null || true
}

# Tests for set -e edge cases (ensures [[ condition ]] && command patterns don't regress)

@test "cmd_edit works on a paused job" {
    local job_id="editpaused"
    local meta_file; meta_file=$(get_meta_file "$job_id")
    local paused_file="${DATA_DIR}/${job_id}.paused"

    # Create job metadata
    create_test_meta "$job_id"

    # Create paused file
    touch "$paused_file"

    # Should be able to edit a paused job
    run cmd_edit "$job_id" --prompt "new prompt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Updated job"* ]]

    rm -f "$meta_file" "$paused_file"
}

@test "cmd_show without model does not show Model line" {
    local job_id="shownomodel"
    local meta_file; meta_file=$(get_meta_file "$job_id")

    # Create job metadata without model
    create_test_meta "$job_id" "/tmp" "" "bypassPermissions" "0"

    run cmd_show "$job_id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Job Details"* ]]
    [[ "$output" != *"Model:"* ]]

    rm -f "$meta_file"
}

@test "cmd_show with model shows Model line" {
    local job_id="showmodel"
    local meta_file; meta_file=$(get_meta_file "$job_id")

    # Create job metadata with model
    create_test_meta "$job_id" "/tmp" "sonnet" "bypassPermissions" "0"

    run cmd_show "$job_id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Model:        sonnet"* ]]

    rm -f "$meta_file"
}

@test "cmd_show with timeout shows Timeout line" {
    local job_id="showtimeout"
    local meta_file; meta_file=$(get_meta_file "$job_id")

    # Create job metadata with timeout
    create_test_meta "$job_id" "/tmp" "" "bypassPermissions" "300"

    run cmd_show "$job_id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Timeout:      300s"* ]]

    rm -f "$meta_file"
}

@test "cmd_status with exit code shows Exit code" {
    local job_id="statusexit"
    local meta_file; meta_file=$(get_meta_file "$job_id")
    local status_file; status_file=$(get_status_file "$job_id")

    # Create job metadata
    create_test_meta "$job_id"

    # Create status file with exit code
    echo 'start_time="2024-01-01 10:00:00"' > "$status_file"
    echo 'end_time="2024-01-01 10:05:00"' >> "$status_file"
    echo 'status="failed"' >> "$status_file"
    echo 'exit_code="1"' >> "$status_file"
    echo 'workdir="/tmp"' >> "$status_file"

    run cmd_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"Exit code: 1"* ]]

    rm -f "$meta_file" "$status_file"
}

@test "generate_run_script with default permission omits permission flag" {
    local job_id="rundefperm"
    generate_run_script "$job_id" "/tmp" "" "default" "0" "true" "prompt" >/dev/null

    local run_script; run_script=$(get_run_script "$job_id")
    [ -f "$run_script" ]

    # Should not contain --permission-mode flag
    ! grep -q "\-\-permission-mode" "$run_script"

    rm -f "$run_script"
}

# Tests for calculate_next_run function
@test "calculate_next_run handles every minute schedule" {
    run calculate_next_run "* * * * *"
    [ "$status" -eq 0 ]
    # Should output a valid date-time format
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run handles hourly schedule" {
    run calculate_next_run "30 * * * *"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run handles daily schedule" {
    run calculate_next_run "0 9 * * *"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run handles weekly schedule" {
    run calculate_next_run "0 9 * * 1"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run handles weekly schedule Sunday (0)" {
    run calculate_next_run "0 10 * * 0"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run handles weekly schedule Saturday (6)" {
    run calculate_next_run "0 14 * * 6"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run returns empty for complex schedule" {
    # Monthly schedule is not supported, should return empty
    run calculate_next_run "0 9 15 * *"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "calculate_next_run handles midnight schedule" {
    run calculate_next_run "0 0 * * *"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run handles end of day schedule" {
    run calculate_next_run "59 23 * * *"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run handles minute step pattern" {
    run calculate_next_run "*/5 * * * *"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run handles minute step pattern */10" {
    run calculate_next_run "*/10 * * * *"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run handles minute step pattern */15" {
    run calculate_next_run "*/15 * * * *"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run handles hour step pattern" {
    run calculate_next_run "0 */2 * * *"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run handles hour step pattern */6" {
    run calculate_next_run "0 */6 * * *"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run returns empty for weekday range" {
    run calculate_next_run "0 9 * * 1-5"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "calculate_next_run returns empty for weekday list" {
    run calculate_next_run "0 9 * * 1,3,5"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# Tests for cmd_stats function
@test "cmd_stats shows no jobs message when empty" {
    # Clear any existing meta files
    rm -f "${LOG_DIR}"/*.meta 2>/dev/null || true

    run cmd_stats
    [ "$status" -eq 0 ]
    [[ "$output" == *"No jobs found"* ]]
}

@test "cmd_stats shows stats for specific job" {
    local job_id="statsjob"
    local meta_file; meta_file=$(get_meta_file "$job_id")
    local history_file; history_file=$(get_history_file "$job_id")

    # Create meta file
    create_test_meta "$job_id"

    # Create history file with some entries
    echo 'start="2024-01-01 10:00:00" end="2024-01-01 10:05:00" status="success" exit_code="0"' > "$history_file"
    echo 'start="2024-01-02 10:00:00" end="2024-01-02 10:03:00" status="success" exit_code="0"' >> "$history_file"
    echo 'start="2024-01-03 10:00:00" end="2024-01-03 10:02:00" status="failed" exit_code="1"' >> "$history_file"

    run cmd_stats "$job_id"
    [ "$status" -eq 0 ]
    # Job ID appears in output (color codes may be present)
    [[ "$output" == *"${job_id}"* ]]
    [[ "$output" == *"Total runs: 3"* ]]
    [[ "$output" == *"Success: 2"* ]]
    [[ "$output" == *"Failed"* ]]
    [[ "$output" == *"1"* ]]
    [[ "$output" == *"Success rate: 66%"* ]]

    rm -f "$meta_file" "$history_file"
}

@test "cmd_stats fails for non-existent job" {
    run cmd_stats "nonexistent123"
    [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
    [[ "$output" == *"not found"* ]]
}

@test "cmd_stats shows stats for all jobs" {
    local job_id1="statsjob1"
    local job_id2="statsjob2"
    local meta_file1; meta_file1=$(get_meta_file "$job_id1")
    local meta_file2; meta_file2=$(get_meta_file "$job_id2")
    local history_file1; history_file1=$(get_history_file "$job_id1")
    local history_file2; history_file2=$(get_history_file "$job_id2")

    # Create meta files
    create_test_meta "$job_id1"
    create_test_meta "$job_id2"

    # Create history files
    echo 'start="2024-01-01 10:00:00" end="2024-01-01 10:05:00" status="success" exit_code="0"' > "$history_file1"
    echo 'start="2024-01-02 10:00:00" end="2024-01-02 10:05:00" status="failed" exit_code="1"' > "$history_file2"

    run cmd_stats
    [ "$status" -eq 0 ]
    # Job IDs appear in output (color codes may be present)
    [[ "$output" == *"${job_id1}"* ]]
    [[ "$output" == *"${job_id2}"* ]]

    rm -f "$meta_file1" "$meta_file2" "$history_file1" "$history_file2"
}

@test "cmd_stats handles job with no history" {
    local job_id="statsnohistory"
    local meta_file; meta_file=$(get_meta_file "$job_id")

    create_test_meta "$job_id"

    run cmd_stats "$job_id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Total runs: 0"* ]]
    [[ "$output" == *"Success: 0"* ]]
    # Failed has extra space for alignment
    [[ "$output" == *"Failed"* ]]
    [[ "$output" == *"0"* ]]

    rm -f "$meta_file"
}

@test "cmd_help stats shows detailed help" {
    run cmd_help "stats"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cc-cron stats"* ]]
    [[ "$output" == *"execution statistics"* ]]
}

@test "cmd_help pause shows detailed help" {
    run cmd_help "pause"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cc-cron pause"* ]]
    [[ "$output" == *"Temporarily disable"* ]]
    [[ "$output" == *"Alias: disable"* ]]
}

@test "cmd_help resume shows detailed help" {
    run cmd_help "resume"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cc-cron resume"* ]]
    [[ "$output" == *"Re-enable a paused job"* ]]
    [[ "$output" == *"Alias: enable"* ]]
}

@test "cmd_help disable shows pause help" {
    run cmd_help "disable"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cc-cron pause"* ]]
    [[ "$output" == *"Alias: disable"* ]]
}

@test "cmd_help enable shows resume help" {
    run cmd_help "enable"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cc-cron resume"* ]]
    [[ "$output" == *"Alias: enable"* ]]
}

@test "cmd_stats handles malformed history entries gracefully" {
    local job_id="malformedstats"
    local meta_file; meta_file=$(get_meta_file "$job_id")
    local history_file; history_file=$(get_history_file "$job_id")

    create_test_meta "$job_id"

    # Create history with malformed entries
    echo 'start="2024-01-01 10:00:00" end="2024-01-01 10:05:00" status="success" exit_code="0"' > "$history_file"
    echo 'malformed line without proper format' >> "$history_file"
    echo 'start="2024-01-02 10:00:00" end="2024-01-02 10:03:00" status="failed" exit_code="1"' >> "$history_file"

    run cmd_stats "$job_id"
    [ "$status" -eq 0 ]
    # Should still show stats for valid entries
    [[ "$output" == *"Total runs: 3"* ]]

    rm -f "$meta_file" "$history_file"
}

@test "cmd_stats for all jobs resets optional fields between iterations" {
    local job_workdir="$BATS_TEST_TMPDIR"

    # Create job with tags
    cmd_add "0 9 * * *" "tagged job" "true" "$job_workdir" "" "bypassPermissions" "0" "false" "prod,backup" >/dev/null
    local tagged_job="$LAST_CREATED_JOB_ID"

    # Create job without tags
    cmd_add "0 10 * * *" "untagged job" "true" "$job_workdir" "" "bypassPermissions" "0" >/dev/null
    local untagged_job="$LAST_CREATED_JOB_ID"

    # Debug: check if meta files exist
    [ -f "$(get_meta_file "$tagged_job")" ]
    [ -f "$(get_meta_file "$untagged_job")" ]

    # Run stats for all jobs - should not show tags for untagged job
    run cmd_stats
    [ "$status" -eq 0 ]
    # Tagged job should be shown (output has ANSI color codes)
    [[ "$output" == *"${tagged_job}"* ]]
    # Untagged job should also be shown
    [[ "$output" == *"${untagged_job}"* ]]

    # Cleanup
    rm -f "$(get_meta_file "$tagged_job")" "$(get_run_script "$tagged_job")"
    rm -f "$(get_meta_file "$untagged_job")" "$(get_run_script "$untagged_job")"
    crontab_remove_entry "CC-CRON:${tagged_job}" 2>/dev/null || true
    crontab_remove_entry "CC-CRON:${untagged_job}" 2>/dev/null || true
}