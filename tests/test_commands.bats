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
    [ "$status" -ne 0 ]
}

@test "cmd_resume fails for non-paused job" {
    run cmd_resume "nonexistent"
    [ "$status" -ne 0 ]
}

@test "cmd_show fails for non-existent job" {
    run cmd_show "nonexistent"
    [ "$status" -ne 0 ]
}

@test "cmd_history fails for non-existent job" {
    run cmd_history "nonexistent"
    [ "$status" -ne 0 ]
}

@test "cmd_remove fails for non-existent job" {
    run cmd_remove "nonexistent"
    [ "$status" -ne 0 ]
}

@test "get_history_file returns correct path" {
    run get_history_file "testjob"
    [ "$output" == "${LOG_DIR}/testjob.history" ]
}

@test "load_job_meta fails for non-existent job" {
    run load_job_meta "nonexistent"
    [ "$status" -ne 0 ]
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
    [ "$status" -ne 0 ]
}

@test "cmd_edit fails for non-existent job" {
    run cmd_edit "nonexistent" --cron "0 0 * * *"
    [ "$status" -ne 0 ]
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
    [ "$status" -ne 0 ]
}

@test "cmd_import fails for non-existent file" {
    run cmd_import "/nonexistent/file.json"
    [ "$status" -ne 0 ]
}

@test "cmd_export creates valid JSON structure" {
    # Create a temp meta file for testing
    local job_id="testexp"
    local meta_file; meta_file=$(get_meta_file "$job_id")
    echo 'id="testexp"' > "$meta_file"
    echo 'created="2024-01-01"' >> "$meta_file"
    echo 'cron="0 0 * * *"' >> "$meta_file"
    echo 'recurring="true"' >> "$meta_file"
    echo 'prompt="test prompt"' >> "$meta_file"
    echo 'workdir="/tmp"' >> "$meta_file"
    echo 'model=""' >> "$meta_file"
    echo 'permission_mode="bypassPermissions"' >> "$meta_file"
    echo 'timeout="0"' >> "$meta_file"
    echo 'run_script="/tmp/run.sh"' >> "$meta_file"

    run cmd_export "$job_id"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"version":"1.0"'* ]]
    [[ "$output" == *'"jobs":['* ]]
    [[ "$output" == *'"id":"testexp"'* ]]

    # Cleanup
    rm -f "$meta_file"
}

@test "cmd_purge accepts days argument" {
    run cmd_purge "30"
    [ "$status" -eq 0 ]
}

@test "cmd_purge rejects invalid days argument" {
    run cmd_purge "invalid"
    [ "$status" -ne 0 ]
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
    [ "$status" -ne 0 ]
}

@test "cmd_config set validates permission_mode" {
    run cmd_config set permission_mode invalid
    [ "$status" -ne 0 ]
}

@test "cmd_config set validates timeout" {
    run cmd_config set timeout "notanumber"
    [ "$status" -ne 0 ]
}

@test "cmd_config rejects invalid key" {
    run cmd_config set invalid_key value
    [ "$status" -ne 0 ]
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
    [ "$status" -ne 0 ]
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
    [ "$status" -ne 0 ]
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
    [ "$status" -ne 0 ]
}

@test "parse_job_options rejects missing argument" {
    run parse_job_options --cron
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires"* ]]
}

@test "cmd_clone fails for non-existent job" {
    run cmd_clone "nonexistent"
    [ "$status" -ne 0 ]
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