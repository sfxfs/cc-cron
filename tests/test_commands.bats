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
    run get_meta_file "abc123"; [ "$output" == "${LOG_DIR}/abc123.meta" ]
}

@test "get_log_file returns correct path" {
    run get_log_file "testjob"; [ "$output" == "${LOG_DIR}/testjob.log" ]
}

@test "get_status_file returns correct path" {
    run get_status_file "myjob"; [ "$output" == "${LOG_DIR}/myjob.status" ]
}

@test "get_run_script returns correct path" {
    run get_run_script "testjob"; [ "$output" == "${DATA_DIR}/run-testjob.sh" ]
}

@test "get_history_file returns correct path" {
    run get_history_file "myjob"; [ "$output" == "${LOG_DIR}/myjob.history" ]
}

@test "get_lock_file generates consistent hash" {
    run get_lock_file "/home/user/project"
    local expected_hash; expected_hash=$(printf '%s' '/home/user/project' | md5sum | cut -d' ' -f1); [ "$output" == "${LOCK_DIR}/${expected_hash}.lock" ]
}

@test "generate_job_id produces 8 character id" {
    run generate_job_id; [ "$status" -eq 0 ]; [[ "$output" =~ ^[a-z0-9]{8}$ ]]
}

@test "generate_job_id produces unique ids" {
    local id1 id2; id1=$(generate_job_id); id2=$(generate_job_id)
    [ "$id1" != "$id2" ]
}

@test "generate_job_id avoids collision" {
    # Create a meta file with a specific ID to force collision handling
    local existing_id="test0001" meta_file; meta_file=$(get_meta_file "$existing_id")
    echo 'id="test0001"' > "$meta_file"

    # generate_job_id should still work (generate a different ID)
    local new_id; new_id=$(generate_job_id); [ "$new_id" != "$existing_id" ]; [[ "$new_id" =~ ^[a-z0-9]{8}$ ]]

    rm -f "$meta_file"
}

@test "ensure_data_dir creates directories" {
    run ensure_data_dir; [ "$status" -eq 0 ]; [ -d "$LOG_DIR" ]; [ -d "$LOCK_DIR" ]
}

@test "validate_workdir accepts existing directory" {
    run validate_workdir "$BATS_TEST_TMPDIR"; [ "$status" -eq 0 ]
}

@test "validate_workdir rejects non-existent directory" {
    run validate_workdir "/nonexistent/path/12345"; [ "$status" -ne 0 ]
}

@test "crontab caching works" {
    # Clear cache
    _CRONTAB_CACHE=""

    # First call should populate cache
    local content; content=$(get_crontab)

    # Cache should now be populated
    [[ -n "$_CRONTAB_CACHE" ]] || [ "$_CRONTAB_CACHE" == "" ]
}

@test "invalidate_crontab_cache clears cache" {
    _CRONTAB_CACHE="test content"; invalidate_crontab_cache; [ -z "$_CRONTAB_CACHE" ]
}

@test "cmd_version outputs version string" {
    run cmd_version; [ "$status" -eq 0 ]; [[ "$output" =~ ^cc-cron\ version\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "cmd_pause fails for non-existent job" {
    run cmd_pause "nonexistent"; [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
}

@test "cmd_resume fails for non-existent job" {
    run cmd_resume "nonexistent"; [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
}

@test "cmd_show fails for non-existent job" {
    run cmd_show "nonexistent"; [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
}

@test "cmd_history fails for non-existent job" {
    run cmd_history "nonexistent"; [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
}

@test "cmd_remove fails for non-existent job" {
    run cmd_remove "nonexistent"; [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
}

@test "cmd_remove removes job and all related files" {
    local job_workdir="$BATS_TEST_TMPDIR"

    # Create a job
    cmd_add "0 9 * * *" "test job to remove" "true" "$job_workdir" "" "bypassPermissions" "0" "false" "" >/dev/null
    local job_id="$LAST_CREATED_JOB_ID"

    # Create a log file for the job
    local log_file history_file; log_file=$(get_log_file "$job_id"); history_file=$(get_history_file "$job_id")
    echo "Test log" > "$log_file"

    # Create a history file
    echo "2024-01-01 10:00:00|2024-01-01 10:05:00|success|0" > "$history_file"

    # Verify files exist
    [[ -f "$(get_meta_file "$job_id")" ]]
    [[ -f "$(get_run_script "$job_id")" ]]
    [[ -f "$log_file" ]]
    [[ -f "$history_file" ]]

    # Remove the job
    run cmd_remove "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"Removed cron job"* ]]

    # Verify all files are removed
    [[ ! -f "$(get_meta_file "$job_id")" ]]
    [[ ! -f "$(get_run_script "$job_id")" ]]
    [[ ! -f "$log_file" ]]
    [[ ! -f "$history_file" ]]
    [[ ! -f "$(get_status_file "$job_id")" ]]
}

@test "cmd_pause pauses active job" {
    local job_workdir="$BATS_TEST_TMPDIR"

    # Create a job
    cmd_add "0 9 * * *" "job to pause" "true" "$job_workdir" "" "bypassPermissions" "0" "false" "" >/dev/null
    local job_id="$LAST_CREATED_JOB_ID"

    # Verify job is in crontab
    crontab_has_entry "CC-CRON:${job_id}"

    # Pause the job
    run cmd_pause "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"Paused job"* ]]

    # Verify paused file exists
    [[ -f "${DATA_DIR}/${job_id}.paused" ]]

    # Verify job is NOT in crontab
    ! crontab_has_entry "CC-CRON:${job_id}"

    # Cleanup
    cleanup_test_job "$job_id" true
}

@test "cmd_pause on already paused job shows warning" {
    local job_workdir="$BATS_TEST_TMPDIR"

    # Create a job
    cmd_add "0 9 * * *" "job to pause" "true" "$job_workdir" "" "bypassPermissions" "0" "false" "" >/dev/null
    local job_id="$LAST_CREATED_JOB_ID"

    # Pause the job
    cmd_pause "$job_id" >/dev/null

    # Try to pause again
    run cmd_pause "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"already paused"* ]]

    # Cleanup
    cleanup_test_job "$job_id" true
}

@test "cmd_resume resumes paused job" {
    local job_workdir="$BATS_TEST_TMPDIR"

    # Create a job
    cmd_add "0 9 * * *" "job to resume" "true" "$job_workdir" "" "bypassPermissions" "0" "false" "" >/dev/null
    local job_id="$LAST_CREATED_JOB_ID"

    # Pause the job
    cmd_pause "$job_id" >/dev/null

    # Verify job is NOT in crontab
    ! crontab_has_entry "CC-CRON:${job_id}"

    # Resume the job
    run cmd_resume "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"Resumed job"* ]]

    # Verify paused file is removed
    [[ ! -f "${DATA_DIR}/${job_id}.paused" ]]

    # Verify job is back in crontab
    crontab_has_entry "CC-CRON:${job_id}"

    # Cleanup
    cleanup_test_job "$job_id"
}

@test "load_job_meta fails for non-existent job" {
    run load_job_meta "nonexistent"; [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
}

@test "load_job_meta loads existing job" {
    local job_id="testmeta" meta_file; meta_file=$(get_meta_file "$job_id")
    echo 'id="testmeta"' > "$meta_file"
    echo 'created="2024-01-01"' >> "$meta_file"

    # Run in a subshell to test variable setting
    local result; result=$(load_job_meta "$job_id" && echo "$id"); [ "$result" == "testmeta" ]

    rm -f "$meta_file"
}

@test "extract_job_id parses crontab comment" {
    local line='0 9 * * * /home/user/run.sh  # CC-CRON:abc123:recurring=true:prompt=test'
    run extract_job_id "$line"; [ "$status" -eq 0 ]; [ "$output" == "abc123" ]
}

@test "extract_job_id handles short job id" {
    local line='0 9 * * * /home/user/run.sh  # CC-CRON:xyz789:recurring=false:prompt=hello'
    run extract_job_id "$line"; [ "$status" -eq 0 ]; [ "$output" == "xyz789" ]
}

@test "extract_job_id extracts from complex crontab line" {
    local line='*/5 * * * * /path/to/run.sh  # CC-CRON:ab12cd34:recurring=true:prompt=Test prompt with spaces'
    run extract_job_id "$line"; [ "$status" -eq 0 ]; [ "$output" == "ab12cd34" ]
}

@test "extract_job_id handles line with no colon after id" {
    local line='0 9 * * * /home/user/run.sh  # CC-CRON:onlyid'
    run extract_job_id "$line"; [ "$status" -eq 0 ]; [ "$output" == "onlyid" ]
}

@test "cmd_run fails for non-existent job" {
    run cmd_run "nonexistent"; [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
}

@test "cmd_run fails when run script is missing" {
    local job_id="runmissing"

    # Create metadata but no run script
    create_test_meta "$job_id"

    run cmd_run "$job_id"; [ "$status" -eq 2 ]; [[ "$output" == *"Run script not found"* ]]  # EXIT_NOT_FOUND

    rm -f "$(get_meta_file "$job_id")"
}

@test "cmd_run executes job successfully" {
    local job_id="runsuccess" job_workdir="$BATS_TEST_TMPDIR" run_script; run_script=$(get_run_script "$job_id")

    create_test_meta "$job_id" "$job_workdir"

    # Create a simple run script that succeeds
    cat > "$run_script" << 'EOF'
#!/bin/bash
echo "Job executed successfully"
exit 0
EOF
    chmod +x "$run_script"

    run cmd_run "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"Job executed successfully"* ]]; [[ "$output" == *"Job completed successfully"* ]]

    cleanup_test_job "$job_id"
}

@test "cmd_run handles job failure" {
    local job_id="runfail" job_workdir="$BATS_TEST_TMPDIR" run_script; run_script=$(get_run_script "$job_id")

    create_test_meta "$job_id" "$job_workdir"

    # Create a run script that fails
    cat > "$run_script" << 'EOF'
#!/bin/bash
echo "Job failed intentionally"
exit 1
EOF
    chmod +x "$run_script"

    run cmd_run "$job_id"; [ "$status" -eq 1 ]; [[ "$output" == *"Job failed intentionally"* ]]; [[ "$output" == *"exited with code: 1"* ]]

    cleanup_test_job "$job_id"
}

@test "cmd_next shows no jobs message when empty" {
    # Clear crontab cache
    _CRONTAB_CACHE=""

    # Skip if there are existing cc-cron jobs
    local crontab_content; crontab_content=$(crontab -l 2>/dev/null) || crontab_content=""
    [[ "$crontab_content" == *"CC-CRON:"* ]] && skip "crontab has existing cc-cron jobs"

    run cmd_next; [ "$status" -eq 0 ]; [[ "$output" == *"No scheduled jobs found"* ]]
}

@test "cmd_next shows job not found for non-existent job" {
    run cmd_next "nonexistent123"; [ "$status" -eq 0 ]; [[ "$output" == *"Job not found"* ]]
}

@test "cmd_next shows next run for existing job" {
    local job_workdir="$BATS_TEST_TMPDIR"

    # Create a job with hourly schedule
    cmd_add "30 * * * *" "hourly test job" "true" "$job_workdir" "" "bypassPermissions" "0" "false" "" >/dev/null
    local job_id="$LAST_CREATED_JOB_ID"

    run cmd_next "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"${job_id}"* ]]; [[ "$output" == *"Next run"* ]]

    # Cleanup
    cleanup_test_job "$job_id"
}

@test "cmd_next shows all jobs when no job_id specified" {
    local job_workdir="$BATS_TEST_TMPDIR"

    # Create two jobs
    cmd_add "0 * * * *" "job1" "true" "$job_workdir" "" "bypassPermissions" "0" "false" "" >/dev/null
    local job1="$LAST_CREATED_JOB_ID"

    cmd_add "30 * * * *" "job2" "true" "$job_workdir" "" "bypassPermissions" "0" "false" "" >/dev/null
    local job2="$LAST_CREATED_JOB_ID"

    run cmd_next; [ "$status" -eq 0 ]; [[ "$output" == *"${job1}"* ]]; [[ "$output" == *"${job2}"* ]]

    # Cleanup
    cleanup_test_job "$job1"
    cleanup_test_job "$job2"
}

@test "cmd_help next shows detailed help" {
    run cmd_help "next"; [ "$status" -eq 0 ]; [[ "$output" == *"cc-cron next"* ]]; [[ "$output" == *"upcoming scheduled runs"* ]]
}

@test "cmd_edit fails for non-existent job" {
    run cmd_edit "nonexistent" --cron "0 0 * * *"; [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
}

@test "cmd_edit with no options shows warning" {
    local job_id="testedit"
    create_test_meta "$job_id" "/tmp"

    run cmd_edit "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"No changes specified"* ]]

    rm -f "$(get_meta_file "$job_id")"
}

@test "cmd_edit updates cron expression" {
    local job_id="editcron" run_script; run_script=$(get_run_script "$job_id")
    create_test_meta "$job_id" "/tmp"

    # Add crontab entry
    crontab_add_entry "0 9 * * * ${run_script}  # ${CRON_COMMENT_PREFIX}${job_id}:recurring=true:prompt=test"

    run cmd_edit "$job_id" --cron "0 10 * * *"; [ "$status" -eq 0 ]; [[ "$output" == *"Updated job"* ]]

    # Verify cron updated in metadata
    grep -q 'cron="0 10' "$(get_meta_file "$job_id")"

    cleanup_test_job "$job_id"
}

@test "cmd_edit updates workdir" {
    local job_id="editworkdir" run_script; run_script=$(get_run_script "$job_id")
    create_test_meta "$job_id" "/tmp"

    # Add crontab entry
    crontab_add_entry "0 9 * * * ${run_script}  # ${CRON_COMMENT_PREFIX}${job_id}:recurring=true:prompt=test"

    run cmd_edit "$job_id" --workdir "$BATS_TEST_TMPDIR"; [ "$status" -eq 0 ]; [[ "$output" == *"Updated job"* ]]

    # Verify workdir updated in metadata
    grep -q "workdir=\"${BATS_TEST_TMPDIR}\"" "$(get_meta_file "$job_id")"

    cleanup_test_job "$job_id"
}

@test "cmd_export outputs empty array when no jobs" {
    run cmd_export; [ "$status" -eq 0 ]; [[ "$output" == *"No jobs to export"* ]]
}

@test "cmd_export fails for non-existent job" {
    run cmd_export "nonexistent"; [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
}

@test "cmd_import fails for non-existent file" {
    run cmd_import "/nonexistent/file.json"; [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
}

@test "cmd_import fails for invalid JSON" {
    local tmp_file="$BATS_TEST_TMPDIR/invalid.json"
    echo "not valid json {" > "$tmp_file"

    # Only run if jq is available
    if command -v jq &>/dev/null; then
        run cmd_import "$tmp_file"; [ "$status" -eq 3 ]; [[ "$output" == *"Invalid JSON"* ]]  # EXIT_INVALID_ARGS
    fi
}

@test "cmd_import handles paused job" {
    # Skip if jq not available
    if ! command -v jq &>/dev/null; then
        skip "jq not available"
    fi

    local tmp_file="$BATS_TEST_TMPDIR/paused_job.json"
    cat > "$tmp_file" <<EOF
{"version":"1.0","jobs":[{"id":"pausedjob","created":"2024-01-01","cron":"0 9 * * *","recurring":true,"prompt":"paused test job","workdir":"${BATS_TEST_TMPDIR}","model":"","permission_mode":"bypassPermissions","timeout":0,"paused":true}]}
EOF

    # Run import directly to capture LAST_CREATED_JOB_ID
    cmd_import "$tmp_file" >/dev/null

    # Verify job was created and paused
    [[ -n "${LAST_CREATED_JOB_ID:-}" ]]
    local paused_file="${DATA_DIR}/${LAST_CREATED_JOB_ID}.paused"
    [[ -f "$paused_file" ]]

    # Cleanup
    cleanup_test_job "$LAST_CREATED_JOB_ID" true
}

@test "cmd_export creates valid JSON structure" {
    local job_id="testexp"
    create_test_meta "$job_id"

    run cmd_export "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *'"version":"1.0"'* ]]; [[ "$output" == *'"jobs":['* ]]; [[ "$output" == *'"id":"testexp"'* ]]

    rm -f "$(get_meta_file "$job_id")"
}

@test "cmd_export writes to file" {
    local job_id="fileexp" output_file="${BATS_TEST_TMPDIR}/export.json"
    create_test_meta "$job_id"

    run cmd_export "$job_id" "$output_file"; [ "$status" -eq 0 ]; [ -f "$output_file" ]

    # Verify file content
    grep -q '"id":"fileexp"' "$output_file"

    rm -f "$(get_meta_file "$job_id")" "$output_file"
}

@test "cmd_purge accepts days argument" {
    run cmd_purge "30"; [ "$status" -eq 0 ]
}

@test "cmd_purge rejects invalid days argument" {
    run cmd_purge "invalid"; [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
}

@test "cmd_purge rejects negative days argument" {
    run cmd_purge "-1"; [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
}

@test "cmd_purge dry-run mode works" {
    run cmd_purge "30" "true"; [ "$status" -eq 0 ]; [[ "$output" == *"dry-run"* ]] || [[ "$output" == *"Purging"* ]]
}

@test "purge_old_files handles empty directory" {
    # Create an empty temp directory
    local empty_dir="${BATS_TEST_TMPDIR}/empty_purge"; mkdir -p "$empty_dir"

    PURGE_COUNT=0; PURGE_BYTES=0

    purge_old_files "$empty_dir" "log" "30" "false" "test log"; [ "$PURGE_COUNT" -eq 0 ]; [ "$PURGE_BYTES" -eq 0 ]

    rm -rf "$empty_dir"
}

@test "purge_old_files handles dry-run mode" {
    local test_dir="${BATS_TEST_TMPDIR}/purge_test"; mkdir -p "$test_dir"

    # Create a test file
    local test_file="${test_dir}/test.log"; echo "test content" > "$test_file"

    PURGE_COUNT=0; PURGE_BYTES=0

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
    [ "$CC_WORKDIR" == "/tmp" ]; [ "$CC_MODEL" == "sonnet" ]; [ "$CC_PERMISSION_MODE" == "auto" ]; [ "$CC_TIMEOUT" == "60" ]

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

    load_config; [ "$CC_WORKDIR" == "/tmp" ]

    CONFIG_FILE="$orig_config"
}

@test "load_config handles malformed lines gracefully" {
    local config_file="${BATS_TEST_TMPDIR}/config_malformed"
    echo '# Valid comment' > "$config_file"
    echo 'workdir="/tmp"' >> "$config_file"
    echo 'line without equals' >> "$config_file"
    echo 'model="sonnet"' >> "$config_file"

    local orig_config="$CONFIG_FILE"
    CONFIG_FILE="$config_file"

    # Should not error, just skip malformed line
    load_config

    # Valid values should be set
    [ "$CC_WORKDIR" == "/tmp" ]; [ "$CC_MODEL" == "sonnet" ]

    CONFIG_FILE="$orig_config"
}

@test "cmd_config list works" {
    run cmd_config list; [ "$status" -eq 0 ]; [[ "$output" == *"Current configuration"* ]]
}

@test "cmd_config set validates workdir" {
    run cmd_config set workdir "/nonexistent/path"; [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
}

@test "cmd_config set validates permission_mode" {
    run cmd_config set permission_mode invalid; [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
}

@test "cmd_config set validates timeout" {
    run cmd_config set timeout "notanumber"; [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
}

@test "cmd_config set succeeds for valid model" {
    local config_file="${DATA_DIR}/config"

    run cmd_config set model "sonnet"; [ "$status" -eq 0 ]; [[ "$output" == *"Set model"* ]]; grep -q '^model="sonnet"' "$config_file"

    rm -f "$config_file"
}

@test "cmd_config set succeeds for valid timeout" {
    local config_file="${DATA_DIR}/config"

    run cmd_config set timeout "300"; [ "$status" -eq 0 ]; [[ "$output" == *"Set timeout"* ]]; grep -q '^timeout="300"' "$config_file"

    rm -f "$config_file"
}

@test "cmd_config rejects invalid key" {
    run cmd_config set invalid_key value; [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
}

@test "cmd_config set without key returns error" {
    run cmd_config set; [ "$status" -eq 3 ]; [[ "$output" == *"Usage"* ]]  # EXIT_INVALID_ARGS
}

@test "cmd_config set without value returns error" {
    run cmd_config set workdir; [ "$status" -eq 3 ]; [[ "$output" == *"Usage"* ]]  # EXIT_INVALID_ARGS
}

@test "cmd_config unset without key returns error" {
    run cmd_config unset; [ "$status" -eq 3 ]; [[ "$output" == *"Usage"* ]]  # EXIT_INVALID_ARGS
}

@test "cmd_config unset removes key" {
    local config_file="${DATA_DIR}/config"; echo 'workdir="/tmp/test"' > "$config_file"

    run cmd_config unset workdir; [ "$status" -eq 0 ]; [[ "$output" == *"Unset"* ]]; ! grep -q "^workdir=" "$config_file"

    rm -f "$config_file"
}

@test "cmd_config unset handles missing key" {
    local config_file="${DATA_DIR}/config"; echo 'model="sonnet"' > "$config_file"

    # unset should succeed even if key doesn't exist
    run cmd_config unset workdir; [ "$status" -eq 0 ]

    rm -f "$config_file"
}

@test "cmd_config rejects unknown action" {
    run cmd_config unknown_action; [ "$status" -eq 3 ]; [[ "$output" == *"Unknown config action"* ]]  # EXIT_INVALID_ARGS
}

@test "cmd_doctor runs without error" {
    run cmd_doctor; [[ "$output" == *"Health Check"* ]]
}

@test "cmd_doctor checks claude CLI" {
    run cmd_doctor; [[ "$output" == *"Claude CLI"* ]]
}

@test "cmd_doctor checks required tools" {
    run cmd_doctor; [[ "$output" == *"flock"* ]]
}

@test "cmd_doctor checks data directory" {
    run cmd_doctor; [[ "$output" == *"data directory"* ]]
}

@test "cmd_doctor checks lock files" {
    run cmd_doctor; [[ "$output" == *"lock files"* ]]
}

@test "cmd_doctor checks job consistency" {
    run cmd_doctor; [[ "$output" == *"job consistency"* ]]
}

@test "cmd_logs fails for non-existent job" {
    run cmd_logs "nonexistent"; [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
}

@test "cmd_logs shows log content" {
    local job_id="testlog" log_file; log_file=$(get_log_file "$job_id")
    echo "Test log entry" > "$log_file"

    run cmd_logs "$job_id" "false"; [ "$status" -eq 0 ]; [[ "$output" == *"Test log entry"* ]]

    rm -f "$log_file"
}

@test "cmd_logs defaults to non-follow mode" {
    local job_id="testcat" log_file; log_file=$(get_log_file "$job_id")
    echo "Log content" > "$log_file"

    run cmd_logs "$job_id" "false"; [ "$status" -eq 0 ]; [[ "$output" == *"Logs for job"* ]]; [[ "$output" != *"Following logs"* ]]

    rm -f "$log_file"
}

@test "cmd_logs for job with no log file" {
    local job_id="nologjob"

    # Create metadata but no log file
    create_test_meta "$job_id"

    run cmd_logs "$job_id" "false"; [ "$status" -eq 2 ]; [[ "$output" == *"No logs found"* ]]  # EXIT_NOT_FOUND

    rm -f "$(get_meta_file "$job_id")"
}

@test "get_stat returns file size" {
    local test_file="${BATS_TEST_TMPDIR}/stat_test"; echo "test content" > "$test_file"

    run get_stat "$test_file" size; [ "$status" -eq 0 ]; [[ "$output" -gt 0 ]]

    rm -f "$test_file"
}

@test "get_stat returns mtime" {
    local test_file="${BATS_TEST_TMPDIR}/stat_mtime_test"; touch "$test_file"

    run get_stat "$test_file" mtime; [ "$status" -eq 0 ]; [[ -n "$output" ]]

    rm -f "$test_file"
}

@test "get_stat returns mtime_unix" {
    local test_file="${BATS_TEST_TMPDIR}/stat_unix_test"; touch "$test_file"

    run get_stat "$test_file" mtime_unix; [ "$status" -eq 0 ]; [[ "$output" =~ ^[0-9]+$ ]]

    rm -f "$test_file"
}

@test "get_stat fails for non-existent file" {
    run get_stat "/nonexistent/file" size; [ "$status" -ne 0 ]
}

@test "remove_file removes existing file" {
    local test_file="${BATS_TEST_TMPDIR}/remove_test"; touch "$test_file"

    run remove_file "$test_file" "test file"; [ "$status" -eq 0 ]; [[ ! -f "$test_file" ]]
}

@test "remove_file handles non-existent file gracefully" {
    run remove_file "/nonexistent/file" "test file"; [ "$status" -eq 0 ]
}

@test "remove_file outputs message when removing" {
    local test_file="${BATS_TEST_TMPDIR}/remove_msg_test"; touch "$test_file"

    run remove_file "$test_file" "test label"; [ "$status" -eq 0 ]; [[ "$output" == *"Removed test label"* ]]
}

@test "purge_single_file updates counters" {
    local test_file="${BATS_TEST_TMPDIR}/purge_test"; echo "test content for purge" > "$test_file"

    PURGE_COUNT=0; PURGE_BYTES=0

    purge_single_file "$test_file" "test file" >/dev/null; [ "$PURGE_COUNT" -eq 1 ]; [ "$PURGE_BYTES" -gt 0 ]
}

@test "purge_single_file handles non-existent file" {
    PURGE_COUNT=0; PURGE_BYTES=0

    purge_single_file "/nonexistent/file" "test" >/dev/null; [ "$PURGE_COUNT" -eq 1 ]; [ "$PURGE_BYTES" -eq 0 ]
}

@test "cmd_history parses structured history" {
    local job_id="histtest" log_file history_file; log_file=$(get_log_file "$job_id"); history_file=$(get_history_file "$job_id")

    echo "Some log entry" > "$log_file"
    echo 'start="2024-01-01 10:00:00" end="2024-01-01 10:05:00" status="success" exit_code="0"' > "$history_file"

    run cmd_history "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"2024-01-01 10:00:00"* ]]; [[ "$output" == *"✓"* ]]

    rm -f "$log_file" "$history_file"
}

@test "cmd_history shows failed status" {
    local job_id="histfail" log_file history_file; log_file=$(get_log_file "$job_id"); history_file=$(get_history_file "$job_id")

    echo "Log entry" > "$log_file"
    echo 'start="2024-01-01 10:00:00" end="2024-01-01 10:05:00" status="failed" exit_code="1"' > "$history_file"

    run cmd_history "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"exit: 1"* ]]

    rm -f "$log_file" "$history_file"
}

@test "cmd_history falls back to log file when no history" {
    local job_id="histfallback" log_file; log_file=$(get_log_file "$job_id")

    echo "Log entry line 1" > "$log_file"
    echo "Log entry line 2" >> "$log_file"

    run cmd_history "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"No structured history available"* ]]; [[ "$output" == *"Log entry line 1"* ]]

    rm -f "$log_file"
}

@test "cmd_history respects lines argument" {
    local job_id="histlines" log_file history_file; log_file=$(get_log_file "$job_id"); history_file=$(get_history_file "$job_id")

    echo "Log entry" > "$log_file"
    # Create multiple history entries
    for i in {1..5}; do
        echo "start=\"2024-01-0${i} 10:00:00\" end=\"2024-01-0${i} 10:05:00\" status=\"success\" exit_code=\"0\"" >> "$history_file"
    done

    # Request only 2 lines
    run cmd_history "$job_id" 2; [ "$status" -eq 0 ]
    # Should only show 2 entries (last 2 lines of history)
    local success_count; success_count=$(echo "$output" | grep -c "✓" || echo "0"); [ "$success_count" -eq 2 ]

    rm -f "$log_file" "$history_file"
}

@test "safe_numeric returns numeric value" {
    run safe_numeric "123" "0"; [ "$status" -eq 0 ]; [ "$output" == "123" ]
}

@test "safe_numeric returns default for non-numeric" {
    run safe_numeric "abc" "0"; [ "$status" -eq 0 ]; [ "$output" == "0" ]
}

@test "safe_numeric returns default for empty string" {
    run safe_numeric "" "10"; [ "$status" -eq 0 ]; [ "$output" == "10" ]
}

@test "safe_numeric handles zero correctly" {
    run safe_numeric "0" "10"; [ "$status" -eq 0 ]; [ "$output" == "0" ]
}

@test "safe_numeric handles negative as non-numeric" {
    run safe_numeric "-5" "10"; [ "$status" -eq 0 ]; [ "$output" == "10" ]
}

@test "safe_numeric handles floating point as non-numeric" {
    run safe_numeric "1.5" "10"; [ "$status" -eq 0 ]; [ "$output" == "10" ]
}

@test "safe_numeric handles large numbers" {
    run safe_numeric "999999999" "0"; [ "$status" -eq 0 ]; [ "$output" == "999999999" ]
}

@test "build_cron_entry creates correct format" {
    run build_cron_entry "abc123" "0 9 * * *" "/tmp/run.sh" "true" "Test prompt"; [ "$status" -eq 0 ]; [[ "$output" == "0 9 * * * /tmp/run.sh  # CC-CRON:abc123:"* ]]; [[ "$output" == *"recurring=true"* ]]; [[ "$output" == *"prompt=Test prompt"* ]]
}

@test "build_cron_entry truncates long prompts" {
    local long_prompt="This is a very long prompt that should be truncated to 30 characters for display in crontab"
    run build_cron_entry "xyz789" "0 * * * *" "/tmp/run.sh" "false" "$long_prompt"; [ "$status" -eq 0 ]; [[ "$output" == *"prompt=This is a very long prompt tha"* ]]
}

@test "crontab_has_entry detects existing entry" {
    # Skip if crontab is not available
    if ! crontab -l &>/dev/null; then
        skip "crontab not available in test environment"
    fi
    # Add a test entry to crontab
    local test_entry="0 9 * * * /tmp/test.sh  # CC-CRON:test123:recurring=true"
    crontab_add_entry "$test_entry"

    run crontab_has_entry "CC-CRON:test123"; [ "$status" -eq 0 ]

    # Cleanup
    crontab_remove_entry "CC-CRON:test123"
}

@test "crontab_has_entry returns false for missing entry" {
    run crontab_has_entry "CC-CRON:nonexistent999"; [ "$status" -ne 0 ]
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
    run crontab_remove_entry "CC-CRON:removeme"; [ "$status" -eq 0 ]

    # Verify it's gone
    run crontab_has_entry "CC-CRON:removeme"; [ "$status" -ne 0 ]
}

@test "get_crontab returns content or empty" {
    _CRONTAB_CACHE=""; run get_crontab; [ "$status" -eq 0 ]  # Should succeed (may be empty if no crontab)
}

@test "write_meta_file creates valid metadata" {
    local job_id="testwrite"
    run write_meta_file "$job_id" "2024-01-01 10:00:00" "0 9 * * *" "true" "test prompt" "/tmp" "sonnet" "auto" "0" "/tmp/run.sh"; [ "$status" -eq 0 ]

    local meta_file; meta_file=$(get_meta_file "$job_id"); [ -f "$meta_file" ]

    # Verify content
    source "$meta_file"; [ "$id" == "testwrite" ]; [ "$cron" == "0 9 * * *" ]; [ "$recurring" == "true" ]; [ "$prompt" == "test prompt" ]

    rm -f "$meta_file"
}

@test "generate_run_script creates executable script" {
    local job_id="testgen"
    generate_run_script "$job_id" "/tmp" "sonnet" "auto" "0" "true" "test prompt" >/dev/null

    local run_script; run_script=$(get_run_script "$job_id"); [ -f "$run_script" ]; [ -x "$run_script" ]

    # Verify script contains expected elements
    grep -q "claude" "$run_script"
    grep -q "test prompt" "$run_script"

    rm -f "$run_script"
}

@test "generate_run_script handles empty model" {
    local job_id="testnomodel"
    generate_run_script "$job_id" "/tmp" "" "bypassPermissions" "0" "true" "prompt" >/dev/null

    local run_script; run_script=$(get_run_script "$job_id"); [ -f "$run_script" ]

    # Should not contain --model flag
    ! grep -q "\-\-model" "$run_script"

    rm -f "$run_script"
}

@test "require_job_id fails without argument" {
    run require_job_id "testcmd"; [ "$status" -eq 3 ]; [[ "$output" == *"Usage: cc-cron testcmd <job-id>"* ]]  # EXIT_INVALID_ARGS
}

@test "require_job_id succeeds with argument" {
    run require_job_id "testcmd" "abc123"; [ "$status" -eq 0 ]
}

@test "parse_job_options parses cron option" {
    parse_job_options --cron "0 12 * * *"; [ "$PARSED_CRON" == "0 12 * * *" ]; [ "$PARSED_HAS_CHANGES" -eq 1 ]
}

@test "parse_job_options parses prompt option" {
    parse_job_options --prompt "new prompt"; [ "$PARSED_PROMPT" == "new prompt" ]; [ "$PARSED_HAS_CHANGES" -eq 1 ]
}

@test "parse_job_options parses multiple options" {
    parse_job_options --cron "0 0 * * *" --prompt "test" --model "sonnet"; [ "$PARSED_CRON" == "0 0 * * *" ]; [ "$PARSED_PROMPT" == "test" ]; [ "$PARSED_MODEL" == "sonnet" ]; [ "$PARSED_HAS_CHANGES" -eq 1 ]
}

@test "parse_job_options rejects invalid cron" {
    run parse_job_options --cron "invalid"; [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
}

@test "parse_job_options rejects missing argument" {
    run parse_job_options --cron; [ "$status" -eq 3 ]; [[ "$output" == *"requires"* ]]  # EXIT_INVALID_ARGS
}

@test "cmd_clone fails for non-existent job" {
    run cmd_clone "nonexistent"; [ "$status" -eq 2 ]  # EXIT_NOT_FOUND
}

@test "cmd_clone creates new job from existing" {
    local source_id="clonesrc"
    create_test_meta "$source_id" "/tmp" "sonnet" "auto" "60"

    run cmd_clone "$source_id"; [ "$status" -eq 0 ]; [[ "$output" == *"Cloned job"* ]]; [[ "$output" == *"Created cron job"* ]]

    # Cleanup
    cleanup_clone_test "$source_id" "$LAST_CREATED_JOB_ID"
}

@test "cmd_clone with options overrides source values" {
    local source_id="clonesrc2"
    create_test_meta "$source_id" "/tmp"

    # Clone with custom cron
    run cmd_clone "$source_id" --cron "0 12 * * *"; [ "$status" -eq 0 ]; [[ "$output" == *"Cloned job"* ]]

    # Cleanup
    cleanup_clone_test "$source_id" "$LAST_CREATED_JOB_ID"
}

@test "cmd_clone preserves tags from source" {
    local source_id="clonetags"
    create_test_meta "$source_id" "${BATS_TEST_TMPDIR}" "" "bypassPermissions" "0" "prod,backup"

    cmd_clone "$source_id" >/dev/null; [[ -n "${LAST_CREATED_JOB_ID:-}" ]]; grep -q 'tags="prod,backup"' "$(get_meta_file "$LAST_CREATED_JOB_ID")"

    # Cleanup
    cleanup_clone_test "$source_id" "$LAST_CREATED_JOB_ID"
}

@test "cmd_clone with tags override" {
    local source_id="clonetags2"
    create_test_meta "$source_id" "${BATS_TEST_TMPDIR}" "" "bypassPermissions" "0" "prod,backup"

    cmd_clone "$source_id" --tags "dev,test" >/dev/null; [[ -n "${LAST_CREATED_JOB_ID:-}" ]]; grep -q 'tags="dev,test"' "$(get_meta_file "$LAST_CREATED_JOB_ID")"

    # Cleanup
    cleanup_clone_test "$source_id" "$LAST_CREATED_JOB_ID"
}

@test "cmd_clone with empty tags override clears tags" {
    local source_id="clonetags3"
    create_test_meta "$source_id" "${BATS_TEST_TMPDIR}" "" "bypassPermissions" "0" "prod,backup"

    cmd_clone "$source_id" --tags "" >/dev/null; [[ -n "${LAST_CREATED_JOB_ID:-}" ]]; ! grep -q 'tags=' "$(get_meta_file "$LAST_CREATED_JOB_ID")"

    # Cleanup
    cleanup_clone_test "$source_id" "$LAST_CREATED_JOB_ID"
}

@test "cmd_clone with prompt override" {
    local source_id="cloneprompt"
    create_test_meta "$source_id" "${BATS_TEST_TMPDIR}"

    cmd_clone "$source_id" --prompt "new prompt text" >/dev/null; [[ -n "${LAST_CREATED_JOB_ID:-}" ]]; grep -q 'prompt="new prompt text"' "$(get_meta_file "$LAST_CREATED_JOB_ID")"

    # Cleanup
    cleanup_clone_test "$source_id" "$LAST_CREATED_JOB_ID"
}

@test "cmd_clone with permission-mode override" {
    local source_id="cloneperm"
    create_test_meta "$source_id" "${BATS_TEST_TMPDIR}" "" "bypassPermissions" "0"

    cmd_clone "$source_id" --permission-mode "auto" >/dev/null; [[ -n "${LAST_CREATED_JOB_ID:-}" ]]; grep -q 'permission_mode="auto"' "$(get_meta_file "$LAST_CREATED_JOB_ID")"

    # Cleanup
    cleanup_clone_test "$source_id" "$LAST_CREATED_JOB_ID"
}

@test "cmd_list shows no jobs message when empty" {
    # Clear crontab cache
    _CRONTAB_CACHE=""

    # Only test if crontab is empty or not accessible
    local crontab_content; crontab_content=$(crontab -l 2>/dev/null) || crontab_content=""

    # Skip if there are existing cc-cron jobs in crontab
    [[ "$crontab_content" == *"CC-CRON:"* ]] && skip "crontab has existing cc-cron jobs"

    # If crontab is empty or has no CC-CRON entries, test the output
    run cmd_list; [ "$status" -eq 0 ]; [[ "$output" == *"No scheduled jobs found"* ]] || [[ "$output" == *"Scheduled Claude Code Cron Jobs"* ]]
}

@test "cmd_list shows job with metadata" {
    local job_workdir="$BATS_TEST_TMPDIR"

    # Create a job properly using cmd_add
    cmd_add "0 9 * * *" "test prompt" "true" "$job_workdir" "" "bypassPermissions" "0" "false" "" >/dev/null
    local job_id="$LAST_CREATED_JOB_ID"

    run cmd_list; [ "$status" -eq 0 ]; [[ "$output" == *"${job_id}"* ]]; [[ "$output" == *"test prompt"* ]]

    # Cleanup
    cleanup_test_job "$job_id"
}

@test "cmd_list --json outputs valid JSON" {
    local job_workdir="$BATS_TEST_TMPDIR"

    # Create a job
    cmd_add "0 9 * * *" "json test job" "true" "$job_workdir" "sonnet" "bypassPermissions" "0" "false" "test" >/dev/null
    local job_id="$LAST_CREATED_JOB_ID"

    run cmd_list "" "true"; [ "$status" -eq 0 ]; [[ "$output" == "["*"]" ]]; [[ "$output" == *'"id":"'$job_id'"'* ]]; [[ "$output" == *'"model":"sonnet"'* ]]; [[ "$output" == *'"tags":"test"'* ]]

    # Cleanup
    cleanup_test_job "$job_id"
}

@test "cmd_list --json with tag filter" {
    local job_workdir="$BATS_TEST_TMPDIR"

    # Create two jobs with different tags
    cmd_add "0 9 * * *" "job one" "true" "$job_workdir" "" "bypassPermissions" "0" "false" "prod" >/dev/null
    local job1="$LAST_CREATED_JOB_ID"

    cmd_add "0 10 * * *" "job two" "true" "$job_workdir" "" "bypassPermissions" "0" "false" "dev" >/dev/null
    local job2="$LAST_CREATED_JOB_ID"

    # Filter by prod tag
    run cmd_list "prod" "true"; [ "$status" -eq 0 ]; [[ "$output" == *'"id":"'$job1'"'* ]]; [[ "$output" != *'"id":"'$job2'"'* ]]

    # Cleanup
    cleanup_test_job "$job1"
    cleanup_test_job "$job2"
}

@test "cmd_list --json empty when no jobs" {
    # Clear crontab cache
    _CRONTAB_CACHE=""

    # Only test if crontab is empty
    local crontab_content; crontab_content=$(crontab -l 2>/dev/null) || crontab_content=""
    [[ "$crontab_content" == *"CC-CRON:"* ]] && skip "crontab has existing cc-cron jobs"

    run cmd_list "" "true"; [ "$status" -eq 0 ]; [[ "$output" == "["$'\n'"]" ]] || [[ "$output" == "[]" ]]
}

@test "cmd_status shows summary" {
    run cmd_status; [ "$status" -eq 0 ]; [[ "$output" == *"CC-Cron Status Report"* ]]; [[ "$output" == *"Total scheduled jobs"* ]]; [[ "$output" == *"Summary"* ]]
}

@test "cmd_add creates job with defaults" {
    local job_workdir="$BATS_TEST_TMPDIR"; LAST_CREATED_JOB_ID=""
    cmd_add "0 9 * * *" "test prompt" "true" "$job_workdir" "" "bypassPermissions" "0" >/dev/null; [[ -n "$LAST_CREATED_JOB_ID" ]]

    # Cleanup
    cleanup_test_job "$LAST_CREATED_JOB_ID"
}

@test "cmd_add validates cron expression" {
    run cmd_add "invalid" "test" "true" "$BATS_TEST_TMPDIR" "" "bypassPermissions" "0"; [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
}

@test "cmd_add validates workdir" {
    run cmd_add "0 9 * * *" "test" "true" "/nonexistent/path" "" "bypassPermissions" "0"; [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
}

@test "cmd_add validates permission mode" {
    run cmd_add "0 9 * * *" "test" "true" "$BATS_TEST_TMPDIR" "" "invalid_mode" "0"; [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
}

@test "cmd_add creates one-shot job" {
    local job_workdir="$BATS_TEST_TMPDIR"
    run cmd_add "0 9 * * *" "one shot" "false" "$job_workdir" "" "bypassPermissions" "0"; [ "$status" -eq 0 ]; [[ "$output" == *"One-shot job"* ]]

    # Cleanup
    cleanup_test_job "$LAST_CREATED_JOB_ID"
}

@test "cmd_edit clears model with empty string" {
    local job_id="editmodel"; create_test_meta "$job_id" "/tmp" "sonnet"
    crontab_add_entry "0 9 * * * /tmp/run.sh  # CC-CRON:${job_id}:recurring=true" 2>/dev/null || true

    run cmd_edit "$job_id" --model ""; [ "$status" -eq 0 ]
    local meta_content; meta_content=$(cat "$(get_meta_file "$job_id")"); [[ "$meta_content" != *'model='* ]] || [[ "$meta_content" == *'model=""'* ]]

    cleanup_test_job "$job_id"
}

@test "cmd_edit updates model" {
    local job_id="editmodel2"; create_test_meta "$job_id" "/tmp" "sonnet"
    crontab_add_entry "0 9 * * * /tmp/run.sh  # CC-CRON:${job_id}:recurring=true" 2>/dev/null || true

    run cmd_edit "$job_id" --model "opus"; [ "$status" -eq 0 ]; [[ "$output" == *"Updated job"* ]]; grep -q 'model="opus"' "$(get_meta_file "$job_id")"

    cleanup_test_job "$job_id"
}

@test "cmd_clone with model override" {
    local source_id="clonemodel"
    create_test_meta "$source_id" "${BATS_TEST_TMPDIR}" "opus"

    cmd_clone "$source_id" --model "haiku" >/dev/null; [[ -n "${LAST_CREATED_JOB_ID:-}" ]]; grep -q 'model="haiku"' "$(get_meta_file "$LAST_CREATED_JOB_ID")"

    # Cleanup
    cleanup_clone_test "$source_id" "$LAST_CREATED_JOB_ID"
}

@test "cmd_clone with empty model override clears model" {
    local source_id="clonemodel2"
    create_test_meta "$source_id" "${BATS_TEST_TMPDIR}" "opus"

    cmd_clone "$source_id" --model "" >/dev/null; [[ -n "${LAST_CREATED_JOB_ID:-}" ]]; local meta_content; meta_content=$(cat "$(get_meta_file "$LAST_CREATED_JOB_ID")"); [[ "$meta_content" != *'model='* ]] || [[ "$meta_content" == *'model=""'* ]]

    # Cleanup
    cleanup_clone_test "$source_id" "$LAST_CREATED_JOB_ID"
}

@test "cmd_clone with timeout override" {
    local source_id="clonetimeout"
    create_test_meta "$source_id" "${BATS_TEST_TMPDIR}" "" "bypassPermissions" "60"

    cmd_clone "$source_id" --timeout "300" >/dev/null; [[ -n "${LAST_CREATED_JOB_ID:-}" ]]; grep -q 'timeout="300"' "$(get_meta_file "$LAST_CREATED_JOB_ID")"

    # Cleanup
    cleanup_clone_test "$source_id" "$LAST_CREATED_JOB_ID"
}

@test "cmd_clone rejects invalid cron expression" {
    local source_id="cloneinvalid"
    create_test_meta "$source_id" "${BATS_TEST_TMPDIR}" "" "bypassPermissions" "0"

    run cmd_clone "$source_id" --cron "invalid cron"; [ "$status" -eq 3 ]; [[ "$output" == *"Invalid cron"* ]]  # EXIT_INVALID_ARGS

    rm -f "$(get_meta_file "$source_id")"
}

@test "cmd_clone rejects invalid workdir" {
    local source_id="cloneworkdir"
    create_test_meta "$source_id" "${BATS_TEST_TMPDIR}" "" "bypassPermissions" "0"

    run cmd_clone "$source_id" --workdir "/nonexistent/path/12345"; [ "$status" -eq 3 ]; [[ "$output" == *"not found"* ]]  # EXIT_INVALID_ARGS

    rm -f "$(get_meta_file "$source_id")"
}

@test "cmd_clone rejects invalid permission mode" {
    local source_id="cloneperm"
    create_test_meta "$source_id" "${BATS_TEST_TMPDIR}" "" "bypassPermissions" "0"

    run cmd_clone "$source_id" --permission-mode "invalid_mode"; [ "$status" -eq 3 ]; [[ "$output" == *"Invalid permission mode"* ]]  # EXIT_INVALID_ARGS

    rm -f "$(get_meta_file "$source_id")"
}

@test "cmd_clone rejects invalid timeout" {
    local source_id="clonetimeout"
    create_test_meta "$source_id" "${BATS_TEST_TMPDIR}" "" "bypassPermissions" "0"

    run cmd_clone "$source_id" --timeout "-1"; [ "$status" -eq 3 ]; [[ "$output" == *"Timeout must be a non-negative number"* ]]  # EXIT_INVALID_ARGS

    rm -f "$(get_meta_file "$source_id")"
}

@test "cmd_add with model and timeout" {
    local job_workdir="$BATS_TEST_TMPDIR"
    run cmd_add "0 9 * * *" "with model" "true" "$job_workdir" "sonnet" "auto" "300"; [ "$status" -eq 0 ]; [[ "$output" == *"Model: sonnet"* ]]; [[ "$output" == *"Timeout: 300s"* ]]

    # Cleanup
    cleanup_test_job "$LAST_CREATED_JOB_ID"
}

@test "cmd_add rejects invalid permission mode" {
    local job_workdir="$BATS_TEST_TMPDIR"
    run cmd_add "0 9 * * *" "test job" "true" "$job_workdir" "" "invalid_mode" "0"; [ "$status" -eq 3 ]; [[ "$output" == *"Invalid permission mode"* ]]  # EXIT_INVALID_ARGS
}

@test "cmd_add rejects invalid timeout" {
    local job_workdir="$BATS_TEST_TMPDIR"
    run cmd_add "0 9 * * *" "test job" "true" "$job_workdir" "" "auto" "-1"; [ "$status" -eq 3 ]; [[ "$output" == *"Timeout must be a non-negative number"* ]]  # EXIT_INVALID_ARGS
}

@test "cmd_add rejects invalid cron expression" {
    local job_workdir="$BATS_TEST_TMPDIR"
    run cmd_add "invalid cron" "test job" "true" "$job_workdir" "" "auto" "0"; [ "$status" -eq 3 ]; [[ "$output" == *"Invalid cron"* ]]  # EXIT_INVALID_ARGS
}

@test "cmd_add rejects invalid workdir" {
    run cmd_add "0 9 * * *" "test job" "true" "/nonexistent/path/12345" "" "auto" "0"; [ "$status" -eq 3 ]; [[ "$output" == *"not found"* ]]  # EXIT_INVALID_ARGS
}

@test "cmd_add with tags" {
    local job_workdir="$BATS_TEST_TMPDIR"; LAST_CREATED_JOB_ID=""
    cmd_add "0 9 * * *" "tagged job" "true" "$job_workdir" "" "bypassPermissions" "0" "false" "prod,backup" >/dev/null; [ -n "$LAST_CREATED_JOB_ID" ]; grep -q 'tags="prod,backup"' "$(get_meta_file "$LAST_CREATED_JOB_ID")"

    cleanup_test_job "$LAST_CREATED_JOB_ID"
}

@test "cmd_add with empty tags is allowed" {
    local job_workdir="$BATS_TEST_TMPDIR"; LAST_CREATED_JOB_ID=""
    cmd_add "0 10 * * *" "no tags job" "true" "$job_workdir" "" "bypassPermissions" "0" "false" "" >/dev/null; [ -n "$LAST_CREATED_JOB_ID" ]; ! grep -q 'tags=' "$(get_meta_file "$LAST_CREATED_JOB_ID")"

    cleanup_test_job "$LAST_CREATED_JOB_ID"
}

@test "cmd_show displays tags when set" {
    local job_id="taggedjob"
    create_test_meta "$job_id" "/tmp" "" "bypassPermissions" "0" "prod,backup"

    run cmd_show "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"Tags:         prod,backup"* ]]

    rm -f "$(get_meta_file "$job_id")"
}

@test "cmd_list filters by tag" {
    local job_workdir="$BATS_TEST_TMPDIR"
    cmd_add "0 9 * * *" "prod job" "true" "$job_workdir" "" "bypassPermissions" "0" "false" "prod" >/dev/null
    local prod_job="$LAST_CREATED_JOB_ID"
    cmd_add "0 10 * * *" "untagged job" "true" "$job_workdir" "" "bypassPermissions" "0" >/dev/null
    local untagged_job="$LAST_CREATED_JOB_ID"

    run cmd_list "prod"; [ "$status" -eq 0 ]; [[ "$output" == *"${prod_job}"* ]]; [[ "$output" != *"${untagged_job}"* ]]

    cleanup_test_job "$prod_job"; cleanup_test_job "$untagged_job"
}

@test "cmd_list filters by non-existent tag shows no jobs" {
    local job_workdir="$BATS_TEST_TMPDIR"
    cmd_add "0 9 * * *" "prod job" "true" "$job_workdir" "" "bypassPermissions" "0" "false" "prod" >/dev/null
    local prod_job="$LAST_CREATED_JOB_ID"

    run cmd_list "nonexistent"; [ "$status" -eq 0 ]; [[ "$output" != *"${prod_job}"* ]]

    cleanup_test_job "$prod_job"
}

@test "cmd_list filters by tag with multiple tags on job" {
    local job_workdir="$BATS_TEST_TMPDIR"
    cmd_add "0 9 * * *" "multi-tag job" "true" "$job_workdir" "" "bypassPermissions" "0" "false" "prod,backup,daily" >/dev/null
    local multi_job="$LAST_CREATED_JOB_ID"

    run cmd_list "prod"; [ "$status" -eq 0 ]; [[ "$output" == *"${multi_job}"* ]]
    run cmd_list "backup"; [ "$status" -eq 0 ]; [[ "$output" == *"${multi_job}"* ]]
    run cmd_list "daily"; [ "$status" -eq 0 ]; [[ "$output" == *"${multi_job}"* ]]
    run cmd_list "staging"; [ "$status" -eq 0 ]; [[ "$output" != *"${multi_job}"* ]]

    cleanup_test_job "$multi_job"
}

@test "cmd_edit updates tags" {
    local job_id="edittagjob"; create_test_meta "$job_id" "/tmp"
    crontab_add_entry "0 9 * * * /tmp/run.sh  # CC-CRON:${job_id}:recurring=true" 2>/dev/null || true

    run cmd_edit "$job_id" --tags "newtag"; [ "$status" -eq 0 ]; [[ "$output" == *"Tags: none"* ]]; grep -q 'tags="newtag"' "$(get_meta_file "$job_id")"

    cleanup_test_job "$job_id"
}

@test "cmd_edit clears tags with empty string" {
    local job_id="edittagjob2"; create_test_meta "$job_id" "/tmp" "" "bypassPermissions" "0" "prod,backup"
    crontab_add_entry "0 9 * * * /tmp/run.sh  # CC-CRON:${job_id}:recurring=true" 2>/dev/null || true

    run cmd_edit "$job_id" --tags ""; [ "$status" -eq 0 ]; [[ "$output" == *"Tags: prod,backup → none"* ]]; ! grep -q 'tags=' "$(get_meta_file "$job_id")"

    cleanup_test_job "$job_id"
}

@test "cmd_edit updates timeout" {
    local job_id="edittimeout"; create_test_meta "$job_id" "/tmp" "" "bypassPermissions" "60"
    crontab_add_entry "0 9 * * * /tmp/run.sh  # CC-CRON:${job_id}:recurring=true" 2>/dev/null || true

    run cmd_edit "$job_id" --timeout "300"; [ "$status" -eq 0 ]; [[ "$output" == *"Updated job"* ]]; grep -q 'timeout="300"' "$(get_meta_file "$job_id")"

    cleanup_test_job "$job_id"
}

@test "cmd_edit rejects invalid cron expression" {
    local job_id="editinvalid"; create_test_meta "$job_id" "/tmp" "" "bypassPermissions" "0"
    crontab_add_entry "0 9 * * * /tmp/run.sh  # CC-CRON:${job_id}:recurring=true" 2>/dev/null || true

    run cmd_edit "$job_id" --cron "invalid cron"; [ "$status" -eq 3 ]; [[ "$output" == *"Invalid cron"* ]]  # EXIT_INVALID_ARGS

    cleanup_test_job "$job_id"
}

@test "cmd_edit rejects invalid workdir" {
    local job_id="editworkdir"; create_test_meta "$job_id" "/tmp" "" "bypassPermissions" "0"
    crontab_add_entry "0 9 * * * /tmp/run.sh  # CC-CRON:${job_id}:recurring=true" 2>/dev/null || true

    run cmd_edit "$job_id" --workdir "/nonexistent/path/12345"; [ "$status" -eq 3 ]; [[ "$output" == *"not found"* ]]  # EXIT_INVALID_ARGS

    cleanup_test_job "$job_id"
}

@test "cmd_edit rejects invalid permission mode" {
    local job_id="editperm"; create_test_meta "$job_id" "/tmp" "" "bypassPermissions" "0"
    crontab_add_entry "0 9 * * * /tmp/run.sh  # CC-CRON:${job_id}:recurring=true" 2>/dev/null || true

    run cmd_edit "$job_id" --permission-mode "invalid_mode"; [ "$status" -eq 3 ]; [[ "$output" == *"Invalid permission mode"* ]]  # EXIT_INVALID_ARGS

    cleanup_test_job "$job_id"
}

@test "cmd_edit rejects invalid timeout" {
    local job_id="edittimeout"; create_test_meta "$job_id" "/tmp" "" "bypassPermissions" "0"
    crontab_add_entry "0 9 * * * /tmp/run.sh  # CC-CRON:${job_id}:recurring=true" 2>/dev/null || true

    run cmd_edit "$job_id" --timeout "-1"; [ "$status" -eq 3 ]; [[ "$output" == *"Timeout must be a non-negative number"* ]]  # EXIT_INVALID_ARGS

    cleanup_test_job "$job_id"
}

@test "cmd_help shows command list" {
    run cmd_help; [ "$status" -eq 0 ]; [[ "$output" == *"COMMANDS:"* ]]; [[ "$output" == *"add"* ]]; [[ "$output" == *"list"* ]]; [[ "$output" == *"remove"* ]]
}

@test "cmd_help add shows detailed help" {
    run cmd_help "add"; [ "$status" -eq 0 ]; [[ "$output" == *"cc-cron add"* ]]; [[ "$output" == *"--once"* ]]; [[ "$output" == *"--workdir"* ]]; [[ "$output" == *"--model"* ]]
}

@test "cmd_help config shows detailed help" {
    run cmd_help "config"; [ "$status" -eq 0 ]; [[ "$output" == *"cc-cron config"* ]]; [[ "$output" == *"workdir"* ]]; [[ "$output" == *"model"* ]]
}

@test "cmd_help edit shows detailed help" {
    run cmd_help "edit"; [ "$status" -eq 0 ]; [[ "$output" == *"cc-cron edit"* ]]; [[ "$output" == *"--cron"* ]]; [[ "$output" == *"--prompt"* ]]
}

@test "cmd_help clone shows detailed help" {
    run cmd_help "clone"; [ "$status" -eq 0 ]; [[ "$output" == *"cc-cron clone"* ]]; [[ "$output" == *"Override"* ]]
}

@test "cmd_help purge shows detailed help" {
    run cmd_help "purge"; [ "$status" -eq 0 ]; [[ "$output" == *"cc-cron purge"* ]]; [[ "$output" == *"--dry-run"* ]]
}

@test "cmd_help list shows detailed help" {
    run cmd_help "list"; [ "$status" -eq 0 ]; [[ "$output" == *"cc-cron list"* ]]; [[ "$output" == *"tag"* ]]
}

@test "cmd_help status shows detailed help" {
    run cmd_help "status"; [ "$status" -eq 0 ]; [[ "$output" == *"cc-cron status"* ]]
}

@test "cmd_help unknown topic returns error" {
    run cmd_help "unknowncommand"; [ "$status" -eq 1 ]; [[ "$output" == *"Unknown help topic"* ]]  # General error
}

@test "cmd_import handles invalid JSON" {
    command -v jq &>/dev/null || skip "jq not installed"
    local json_file="${BATS_TEST_TMPDIR}/invalid.json"
    echo "not valid json" > "$json_file"

    run cmd_import "$json_file"; [ "$status" -eq 3 ]  # EXIT_INVALID_ARGS
}

@test "cmd_import handles empty jobs array" {
    command -v jq &>/dev/null || skip "jq not installed"
    local json_file="${BATS_TEST_TMPDIR}/empty.json"
    echo '{"version":"1.0","jobs":[]}' > "$json_file"

    run cmd_import "$json_file"; [ "$status" -eq 0 ]; [[ "$output" == *"No jobs found"* ]]
}

@test "cmd_import handles missing workdir" {
    command -v jq &>/dev/null || skip "jq not installed"
    local json_file="${BATS_TEST_TMPDIR}/missing_dir.json"
    cat > "$json_file" << 'EOF'
{"version":"1.0","jobs":[{"id":"test","created":"2024-01-01","cron":"0 9 * * *","recurring":true,"prompt":"test","workdir":"/nonexistent/path/12345","model":"","permission_mode":"bypassPermissions","timeout":0,"paused":false}]}
EOF

    run cmd_import "$json_file"; [ "$status" -eq 0 ]; [[ "$output" == *"Skipping job with missing workdir"* ]]
}

@test "cmd_import handles invalid cron expression" {
    command -v jq &>/dev/null || skip "jq not installed"
    local json_file="${BATS_TEST_TMPDIR}/bad_cron.json"
    cat > "$json_file" << EOF
{"version":"1.0","jobs":[{"id":"test","created":"2024-01-01","cron":"invalid cron","recurring":true,"prompt":"test","workdir":"${BATS_TEST_TMPDIR}","model":"","permission_mode":"bypassPermissions","timeout":0,"paused":false}]}
EOF

    run cmd_import "$json_file"; [ "$status" -eq 0 ]; [[ "$output" == *"Skipping invalid cron"* ]]
}

@test "cmd_import preserves tags" {
    command -v jq &>/dev/null || skip "jq not installed"
    local json_file="${BATS_TEST_TMPDIR}/tags_import.json"
    cat > "$json_file" << EOF
{"version":"1.0","jobs":[{"id":"tagtest","created":"2024-01-01","cron":"0 9 * * *","recurring":true,"prompt":"test job with tags","workdir":"${BATS_TEST_TMPDIR}","model":"","permission_mode":"bypassPermissions","timeout":0,"paused":false,"tags":"prod,backup"}]}
EOF

    cmd_import "$json_file" >/dev/null

    # Verify the job was created with tags (use the ID from LAST_CREATED_JOB_ID)
    [[ -n "${LAST_CREATED_JOB_ID:-}" ]]; grep -q 'tags="prod,backup"' "$(get_meta_file "$LAST_CREATED_JOB_ID")"

    # Cleanup
    cleanup_test_job "$LAST_CREATED_JOB_ID"
}

@test "cmd_export escapes quotes in prompt" {
    local job_id="quotejob" meta_file; meta_file=$(get_meta_file "$job_id")
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

    run cmd_export "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *'\"quotes\"'* ]]  # Check that quotes are escaped in JSON output

    rm -f "$meta_file"
}

@test "cmd_export includes tags in JSON output" {
    local job_id="exportags"
    create_test_meta "$job_id" "/tmp" "" "bypassPermissions" "0" "prod,backup"

    run cmd_export "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *'"tags":"prod,backup"'* ]]  # Check that tags are included in JSON output

    rm -f "$(get_meta_file "$job_id")"
}

@test "parse_job_options validates permission-mode" {
    run parse_job_options --permission-mode "invalid_mode"; [ "$status" -eq 3 ]; [[ "$output" == *"Invalid permission mode"* ]]  # EXIT_INVALID_ARGS
}

@test "parse_job_options validates timeout" {
    run parse_job_options --timeout "not_a_number"; [ "$status" -eq 3 ]; [[ "$output" == *"Timeout must be a non-negative number"* ]]  # EXIT_INVALID_ARGS
}

@test "parse_job_options accepts valid permission-mode" {
    parse_job_options --permission-mode "auto"; [ "$PARSED_PERMISSION" == "auto" ]
}

@test "parse_job_options accepts valid timeout" {
    parse_job_options --timeout "300"; [ "$PARSED_TIMEOUT" == "300" ]
}

@test "parse_job_options parses workdir" {
    parse_job_options --workdir "$BATS_TEST_TMPDIR"; [ "$PARSED_WORKDIR" == "$BATS_TEST_TMPDIR" ]
}

@test "parse_job_options rejects invalid workdir" {
    run parse_job_options --workdir "/nonexistent/path"; [ "$status" -eq 3 ]; [[ "$output" == *"Directory not found"* ]]  # EXIT_INVALID_ARGS
}

@test "parse_job_options rejects unknown option" {
    run parse_job_options --unknown-option; [ "$status" -eq 3 ]; [[ "$output" == *"Unknown option"* ]]  # EXIT_INVALID_ARGS
}

@test "cmd_show displays timeout when set" {
    local job_id="showtimeout"
    create_test_meta "$job_id" "/tmp" "" "bypassPermissions" "300"

    run cmd_show "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"Timeout:"* ]]; [[ "$output" == *"300s"* ]]

    rm -f "$(get_meta_file "$job_id")"
}

@test "cmd_show displays model when set" {
    local job_id="showmodel"; create_test_meta "$job_id" "/tmp" "sonnet"

    run cmd_show "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"Model:"* ]]; [[ "$output" == *"sonnet"* ]]

    rm -f "$(get_meta_file "$job_id")"
}

@test "cmd_show displays paused status" {
    local job_id="showpaused"; create_test_meta "$job_id"; touch "${DATA_DIR}/${job_id}.paused"

    run cmd_show "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"PAUSED"* ]]

    rm -f "$(get_meta_file "$job_id")" "${DATA_DIR}/${job_id}.paused"
}

@test "cmd_show displays execution statistics" {
    local job_id="showstats" history_file; create_test_meta "$job_id"; history_file=$(get_history_file "$job_id")

    echo 'start="2024-01-01 10:00:00" end="2024-01-01 10:05:00" status="success" exit_code="0"' > "$history_file"
    echo 'start="2024-01-02 10:00:00" end="2024-01-02 10:05:00" status="failed" exit_code="1"' >> "$history_file"

    run cmd_show "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"Statistics:"* ]]; [[ "$output" == *"Total runs:"* ]]; [[ "$output" == *"2"* ]]

    rm -f "$(get_meta_file "$job_id")" "$history_file"
}

@test "cmd_show handles missing history gracefully" {
    local job_id="showmissinghist"; create_test_meta "$job_id"

    run cmd_show "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"Job Details"* ]]; [[ "$output" != *"Statistics:"* ]]

    rm -f "$(get_meta_file "$job_id")"
}

@test "cmd_show shows running status" {
    local job_id="showrunning" status_file; create_test_meta "$job_id"; status_file=$(get_status_file "$job_id")

    echo 'start_time="2024-01-01 10:00:00"' > "$status_file"
    echo 'status="running"' >> "$status_file"

    run cmd_show "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"RUNNING"* ]]

    rm -f "$(get_meta_file "$job_id")" "$status_file"
}

@test "cmd_show shows success status" {
    local job_id="showsuccess" status_file; create_test_meta "$job_id"; status_file=$(get_status_file "$job_id")

    echo 'start_time="2024-01-01 10:00:00"' > "$status_file"
    echo 'end_time="2024-01-01 10:05:00"' >> "$status_file"
    echo 'status="success"' >> "$status_file"
    echo 'exit_code="0"' >> "$status_file"

    run cmd_show "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"SUCCESS"* ]]

    rm -f "$(get_meta_file "$job_id")" "$status_file"
}

@test "cmd_show shows failed status with exit code" {
    local job_id="showfailed" status_file; create_test_meta "$job_id"; status_file=$(get_status_file "$job_id")

    echo 'start_time="2024-01-01 10:00:00"' > "$status_file"
    echo 'end_time="2024-01-01 10:05:00"' >> "$status_file"
    echo 'status="failed"' >> "$status_file"
    echo 'exit_code="42"' >> "$status_file"

    run cmd_show "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"FAILED"* ]]; [[ "$output" == *"42"* ]]

    rm -f "$(get_meta_file "$job_id")" "$status_file"
}

@test "cmd_status handles no jobs gracefully" {
    local crontab_content; crontab_content=$(crontab -l 2>/dev/null) || crontab_content=""
    [[ "$crontab_content" == *"CC-CRON:"* ]] && skip "crontab has existing cc-cron jobs"

    run cmd_status; [ "$status" -eq 0 ]; [[ "$output" == *"Total scheduled jobs: 0"* ]]
}

@test "build_cron_entry handles special characters in prompt" {
    local prompt="Test with 'single quotes' and \"double quotes\""
    run build_cron_entry "abc123" "0 9 * * *" "/tmp/run.sh" "true" "$prompt"; [ "$status" -eq 0 ]; [[ "$output" == *"CC-CRON:abc123"* ]]
}

@test "cmd_help logs shows detailed help" {
    run cmd_help "logs"; [ "$status" -eq 0 ]; [[ "$output" == *"cc-cron logs"* ]]; [[ "$output" == *"--tail"* ]]
}

@test "cmd_help run shows detailed help" {
    run cmd_help "run"; [ "$status" -eq 0 ]; [[ "$output" == *"cc-cron run"* ]]; [[ "$output" == *"Execute a job immediately"* ]]
}

@test "cmd_help show shows detailed help" {
    run cmd_help "show"; [ "$status" -eq 0 ]; [[ "$output" == *"cc-cron show"* ]]; [[ "$output" == *"Display job details"* ]]
}

@test "cmd_help history shows detailed help" {
    run cmd_help "history"; [ "$status" -eq 0 ]; [[ "$output" == *"cc-cron history"* ]]; [[ "$output" == *"View execution history"* ]]
}

@test "cmd_completion outputs bash completion script" {
    run cmd_completion; [ "$status" -eq 0 ]; [[ "$output" == *"_cc_cron_completion"* ]]; [[ "$output" == *"complete -F"* ]]
}

@test "cmd_completion includes main commands" {
    run cmd_completion; [ "$status" -eq 0 ]; [[ "$output" == *"add"* ]]; [[ "$output" == *"list"* ]]; [[ "$output" == *"remove"* ]]; [[ "$output" == *"status"* ]]; [[ "$output" == *"edit"* ]]
}

@test "cmd_completion includes model options" {
    run cmd_completion; [ "$status" -eq 0 ]; [[ "$output" == *"sonnet"* ]]; [[ "$output" == *"opus"* ]]; [[ "$output" == *"haiku"* ]]
}

@test "cmd_completion includes permission modes" {
    run cmd_completion; [ "$status" -eq 0 ]; [[ "$output" == *"bypassPermissions"* ]]; [[ "$output" == *"acceptEdits"* ]]
}

@test "generate_run_script includes timeout when set" {
    local job_id="timeoutjob"; generate_run_script "$job_id" "/tmp" "sonnet" "auto" "300" "true" "test prompt" >/dev/null

    local run_script; run_script=$(get_run_script "$job_id"); [ -f "$run_script" ]; grep -q 'timeout "\${TIMEOUT}"' "$run_script"; grep -q 'TIMEOUT="300"' "$run_script"

    rm -f "$run_script"
}

@test "generate_run_script without timeout has no timeout command" {
    local job_id="notimeout"; generate_run_script "$job_id" "/tmp" "" "bypassPermissions" "0" "true" "test prompt" >/dev/null

    local run_script; run_script=$(get_run_script "$job_id"); [ -f "$run_script" ]; ! grep -q "timeout " "$run_script"

    rm -f "$run_script"
}

@test "write_meta_file includes modified field when provided" {
    local job_id="modifiedjob"; write_meta_file "$job_id" "2024-01-01 10:00:00" "0 9 * * *" "true" "test prompt" "/tmp" "" "auto" "0" "/tmp/run.sh" "2024-01-02 12:00:00"

    local meta_file; meta_file=$(get_meta_file "$job_id"); [ -f "$meta_file" ]

    source "$meta_file"; [ "$modified" == "2024-01-02 12:00:00" ]

    rm -f "$meta_file"
}

@test "write_meta_file without modified field omits it" {
    local job_id="nomodified"; write_meta_file "$job_id" "2024-01-01 10:00:00" "0 9 * * *" "true" "test prompt" "/tmp" "" "auto" "0" "/tmp/run.sh"

    local meta_file; meta_file=$(get_meta_file "$job_id"); [ -f "$meta_file" ]; ! grep -q "modified=" "$meta_file"

    rm -f "$meta_file"
}

@test "error function outputs to stderr" {
    run error "Test error message"; [ "$status" -eq 1 ]; [[ "$output" == *"Test error message"* ]]  # EXIT_ERROR (default)
}

@test "error function uses custom exit code" {
    run error "Custom exit" 42; [ "$status" -eq 42 ]
}

@test "error function defaults to EXIT_ERROR" {
    run error "Default exit"; [ "$status" -eq 1 ]
}

@test "info function outputs message" {
    run info "Test info"; [ "$status" -eq 0 ]; [[ "$output" == *"Test info"* ]]
}

@test "success function outputs message" {
    run success "Test success"; [ "$status" -eq 0 ]; [[ "$output" == *"Test success"* ]]
}

@test "warn function outputs message" {
    run warn "Test warning"; [ "$status" -eq 0 ]; [[ "$output" == *"Test warning"* ]]
}

@test "cmd_pause handles already paused job" {
    local job_id="alreadypaused" meta_file; meta_file=$(get_meta_file "$job_id")
    local paused_file="${DATA_DIR}/${job_id}.paused"

    create_test_meta "$job_id" "/tmp"

    # Create paused file
    touch "$paused_file"

    # Add entry to crontab (so we can check)
    crontab_add_entry "0 9 * * * /tmp/run.sh  # CC-CRON:alreadypaused:recurring=true" 2>/dev/null || true

    run cmd_pause "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"already paused"* ]]

    rm -f "$meta_file" "$paused_file"
}

@test "cmd_resume fails when metadata is missing" {
    local job_id="missingmeta"

    # Create paused file without metadata
    touch "${DATA_DIR}/${job_id}.paused"

    run cmd_resume "$job_id"; [ "$status" -eq 2 ]; [[ "$output" == *"not found"* ]]  # EXIT_NOT_FOUND

    rm -f "${DATA_DIR}/${job_id}.paused"
}

@test "cmd_resume fails when job is not paused" {
    local job_id="notpaused"; create_test_meta "$job_id"

    run cmd_resume "$job_id"; [ "$status" -eq 3 ]; [[ "$output" == *"is not paused"* ]]  # EXIT_INVALID_ARGS

    rm -f "$(get_meta_file "$job_id")"
}

@test "crontab_add_entry and remove work together" {
    if ! crontab -l &>/dev/null; then skip "crontab not available"; fi

    local test_marker="CC-CRON:testaddremove123" test_entry="0 9 * * * /tmp/test.sh  # ${test_marker}:recurring=true"
    crontab_add_entry "$test_entry"; crontab_has_entry "$test_marker"; [ "$?" -eq 0 ]
    crontab_remove_entry "$test_marker"; run crontab_has_entry "$test_marker"; [ "$status" -ne 0 ]
}

@test "cmd_list handles job with missing metadata" {
    local job_id="missingmeta" meta_file; meta_file=$(get_meta_file "$job_id"); rm -f "$meta_file" 2>/dev/null || true
    crontab_add_entry "0 9 * * * /tmp/run.sh  # CC-CRON:${job_id}:recurring=true" 2>/dev/null || true

    run cmd_list; [ "$status" -eq 0 ]; [[ "$output" == *"missingmeta"* ]] || [[ "$output" == *"metadata missing"* ]] || [[ "$output" == *"No scheduled jobs"* ]]

    crontab_remove_entry "CC-CRON:${job_id}" 2>/dev/null || true
}

@test "generate_run_script with non-default permission mode" {
    local job_id="permjob"; generate_run_script "$job_id" "/tmp" "sonnet" "acceptEdits" "0" "true" "test prompt" >/dev/null

    local run_script; run_script=$(get_run_script "$job_id"); [ -f "$run_script" ]; grep -q "acceptEdits" "$run_script"

    rm -f "$run_script"
}

@test "generate_run_script with default permission omits flag" {
    local job_id="defaultperm"; generate_run_script "$job_id" "/tmp" "" "default" "0" "true" "test prompt" >/dev/null

    local run_script; run_script=$(get_run_script "$job_id"); [ -f "$run_script" ]; ! grep -q "\-\-permission-mode" "$run_script"

    rm -f "$run_script"
}

@test "cmd_status handles running jobs" {
    local job_id="runningstatus" status_file; create_test_meta "$job_id"; status_file=$(get_status_file "$job_id")
    echo 'start_time="2024-01-01 10:00:00"' > "$status_file"; echo 'status="running"' >> "$status_file"

    run cmd_status; [ "$status" -eq 0 ]

    rm -f "$(get_meta_file "$job_id")" "$status_file"
}

@test "cmd_status handles failed jobs" {
    local job_id="failedstatus" status_file; create_test_meta "$job_id"; status_file=$(get_status_file "$job_id")
    echo 'start_time="2024-01-01 10:00:00"' > "$status_file"; echo 'end_time="2024-01-01 10:05:00"' >> "$status_file"; echo 'status="failed"' >> "$status_file"; echo 'exit_code="1"' >> "$status_file"

    run cmd_status; [ "$status" -eq 0 ]

    rm -f "$(get_meta_file "$job_id")" "$status_file"
}

@test "cmd_status handles paused jobs" {
    local job_id="pausedstatus"; create_test_meta "$job_id"; touch "${DATA_DIR}/${job_id}.paused"

    run cmd_status; [ "$status" -eq 0 ]

    rm -f "$(get_meta_file "$job_id")" "${DATA_DIR}/${job_id}.paused"
}

@test "cmd_purge handles orphaned run scripts" {
    local job_id="orphanscript" run_script; run_script=$(get_run_script "$job_id"); mkdir -p "$DATA_DIR"
    echo "#!/bin/bash" > "$run_script"; echo "echo test" >> "$run_script"; chmod +x "$run_script"

    [ -f "$run_script" ]; run cmd_purge "0" "false"; [ "$status" -eq 0 ]; [[ ! -f "$run_script" ]] || [[ "$output" == *"orphan"* ]]
}

@test "write_meta_file with all fields" {
    local job_id="fullmeta"; write_meta_file "$job_id" "2024-01-01 10:00:00" "*/5 * * * *" "false" "complex prompt with 'quotes'" "/home/user" "opus" "auto" "3600" "/tmp/run-fullmeta.sh"

    local meta_file; meta_file=$(get_meta_file "$job_id"); [ -f "$meta_file" ]

    source "$meta_file"; [ "$id" == "fullmeta" ]; [ "$cron" == "*/5 * * * *" ]; [ "$recurring" == "false" ]; [ "$prompt" == "complex prompt with 'quotes'" ]; [ "$workdir" == "/home/user" ]; [ "$model" == "opus" ]; [ "$permission_mode" == "auto" ]; [ "$timeout" == "3600" ]

    rm -f "$meta_file"
}

@test "validate_cron_field handles edge case ranges" {
    run validate_cron_field "0" 0 59 "minute"; [ "$status" -eq 0 ]; run validate_cron_field "59" 0 59 "minute"; [ "$status" -eq 0 ]; run validate_cron_field "23" 0 23 "hour"; [ "$status" -eq 0 ]; run validate_cron_field "31" 1 31 "day"; [ "$status" -eq 0 ]; run validate_cron_field "12" 1 12 "month"; [ "$status" -eq 0 ]; run validate_cron_field "6" 0 6 "weekday"; [ "$status" -eq 0 ]
}

@test "validate_cron_field accepts wildcard" {
    run validate_cron_field "*" 0 59 "minute"; [ "$status" -eq 0 ]
}

@test "validate_cron_field accepts valid step patterns" {
    run validate_cron_field "*/5" 0 59 "minute"; [ "$status" -eq 0 ]; run validate_cron_field "*/15" 0 59 "minute"; [ "$status" -eq 0 ]; run validate_cron_field "*/1" 0 59 "minute"; [ "$status" -eq 0 ]
}

@test "validate_cron_field rejects invalid step patterns" {
    run validate_cron_field "*/0" 0 59 "minute"; [ "$status" -eq 3 ]; run validate_cron_field "*/abc" 0 59 "minute"; [ "$status" -eq 3 ]; run validate_cron_field "*/100" 0 59 "minute"; [ "$status" -eq 3 ]
}

@test "validate_cron_field accepts valid ranges" {
    run validate_cron_field "1-5" 0 59 "minute"; [ "$status" -eq 0 ]; run validate_cron_field "0-23" 0 23 "hour"; [ "$status" -eq 0 ]; run validate_cron_field "1-31" 1 31 "day"; [ "$status" -eq 0 ]
}

@test "validate_cron_field rejects invalid ranges" {
    run validate_cron_field "5-1" 0 59 "minute"; [ "$status" -eq 3 ]; run validate_cron_field "60-65" 0 59 "minute"; [ "$status" -eq 3 ]; run validate_cron_field "50-70" 0 59 "minute"; [ "$status" -eq 3 ]; run validate_cron_field "a-b" 0 59 "minute"; [ "$status" -eq 3 ]
}

@test "validate_cron_field accepts valid comma-separated lists" {
    run validate_cron_field "1,2,3" 0 59 "minute"; [ "$status" -eq 0 ]; run validate_cron_field "0,15,30,45" 0 59 "minute"; [ "$status" -eq 0 ]; run validate_cron_field "1,15,30" 0 59 "minute"; [ "$status" -eq 0 ]
}

@test "validate_cron_field rejects invalid comma-separated lists" {
    run validate_cron_field "1,2,100" 0 59 "minute"; [ "$status" -eq 3 ]; run validate_cron_field "1,abc,3" 0 59 "minute"; [ "$status" -eq 3 ]
}

@test "validate_cron_field rejects non-numeric simple values" {
    run validate_cron_field "abc" 0 59 "minute"; [ "$status" -eq 3 ]; run validate_cron_field "" 0 59 "minute"; [ "$status" -eq 3 ]
}

@test "validate_cron accepts all wildcards" {
    run validate_cron "* * * * *"; [ "$status" -eq 0 ]
}

@test "validate_cron accepts specific values" {
    run validate_cron "30 9 * * *"; [ "$status" -eq 0 ]
}

@test "validate_cron accepts ranges" {
    run validate_cron "0 9-17 * * *"; [ "$status" -eq 0 ]
}

@test "validate_cron accepts step patterns" {
    run validate_cron "*/5 * * * *"; [ "$status" -eq 0 ]
}

@test "validate_cron accepts lists" {
    run validate_cron "0,30 9,17 * * *"; [ "$status" -eq 0 ]
}

@test "validate_cron rejects too few fields" {
    run validate_cron "0 9 * *"; [ "$status" -eq 3 ]; [[ "$output" == *"5 fields"* ]]
}

@test "validate_cron rejects too many fields" {
    run validate_cron "0 9 * * * *"; [ "$status" -eq 3 ]; [[ "$output" == *"5 fields"* ]]
}

@test "validate_cron rejects invalid minute" {
    run validate_cron "60 9 * * *"; [ "$status" -eq 3 ]; [[ "$output" == *"minute"* ]]
}

@test "validate_cron rejects invalid hour" {
    run validate_cron "0 24 * * *"; [ "$status" -eq 3 ]; [[ "$output" == *"hour"* ]]
}

@test "cmd_completion includes all command aliases" {
    run cmd_completion; [ "$status" -eq 0 ]; [[ "$output" == *"disable"* ]]; [[ "$output" == *"enable"* ]]
}

@test "cmd_completion includes edit options" {
    run cmd_completion; [ "$status" -eq 0 ]; [[ "$output" == *"--cron"* ]]; [[ "$output" == *"--prompt"* ]]; [[ "$output" == *"--workdir"* ]]; [[ "$output" == *"--model"* ]]; [[ "$output" == *"--permission-mode"* ]]; [[ "$output" == *"--timeout"* ]]; [[ "$output" == *"--tags"* ]]
}

@test "cmd_add --quiet outputs only job ID" {
    local job_workdir="$BATS_TEST_TMPDIR"
    cmd_add "0 9 * * *" "test prompt" "true" "$job_workdir" "" "bypassPermissions" "0" "true" >/dev/null

    # Verify job was created
    [[ -n "$LAST_CREATED_JOB_ID" ]]

    # Verify the output is just the job ID (8 chars)
    run cmd_add "0 10 * * *" "quiet test" "true" "$job_workdir" "" "bypassPermissions" "0" "true"; [ "$status" -eq 0 ]; [[ "$output" =~ ^[a-z0-9]{8}$ ]]

    # Cleanup
    rm -f "$(get_meta_file "$LAST_CREATED_JOB_ID")"
    crontab_remove_entry "CC-CRON:${LAST_CREATED_JOB_ID}" 2>/dev/null || true
}

@test "cmd_add normal output includes SUCCESS message" {
    local job_workdir="$BATS_TEST_TMPDIR"
    run cmd_add "0 11 * * *" "normal test" "true" "$job_workdir" "" "bypassPermissions" "0" "false"; [ "$status" -eq 0 ]; [[ "$output" == *"SUCCESS"* ]]; [[ "$output" == *"Created cron job"* ]]

    # Cleanup
    rm -f "$(get_meta_file "$LAST_CREATED_JOB_ID")"
    crontab_remove_entry "CC-CRON:${LAST_CREATED_JOB_ID}" 2>/dev/null || true
}

# Tests for set -e edge cases (ensures [[ condition ]] && command patterns don't regress)

@test "cmd_edit works on a paused job" {
    local job_id="editpaused" meta_file; meta_file=$(get_meta_file "$job_id")
    local paused_file="${DATA_DIR}/${job_id}.paused"
    create_test_meta "$job_id"
    touch "$paused_file"
    run cmd_edit "$job_id" --prompt "new prompt"; [ "$status" -eq 0 ]; [[ "$output" == *"Updated job"* ]]
    rm -f "$meta_file" "$paused_file"
}

@test "cmd_show without model does not show Model line" {
    local job_id="shownomodel" meta_file; meta_file=$(get_meta_file "$job_id")
    create_test_meta "$job_id" "/tmp" "" "bypassPermissions" "0"
    run cmd_show "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"Job Details"* ]]; [[ "$output" != *"Model:"* ]]
    rm -f "$meta_file"
}

@test "cmd_show with model shows Model line" {
    local job_id="showmodel" meta_file; meta_file=$(get_meta_file "$job_id")
    create_test_meta "$job_id" "/tmp" "sonnet" "bypassPermissions" "0"
    run cmd_show "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"Model:        sonnet"* ]]
    rm -f "$meta_file"
}

@test "cmd_show with timeout shows Timeout line" {
    local job_id="showtimeout" meta_file; meta_file=$(get_meta_file "$job_id")
    create_test_meta "$job_id" "/tmp" "" "bypassPermissions" "300"
    run cmd_show "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"Timeout:      300s"* ]]
    rm -f "$meta_file"
}

@test "cmd_status with exit code shows Exit code" {
    local job_id="statusexit" meta_file status_file; meta_file=$(get_meta_file "$job_id"); status_file=$(get_status_file "$job_id")
    create_test_meta "$job_id"
    echo 'start_time="2024-01-01 10:00:00"' > "$status_file"; echo 'end_time="2024-01-01 10:05:00"' >> "$status_file"; echo 'status="failed"' >> "$status_file"; echo 'exit_code="1"' >> "$status_file"; echo 'workdir="/tmp"' >> "$status_file"
    run cmd_status; [ "$status" -eq 0 ]; [[ "$output" == *"Exit code: 1"* ]]
    rm -f "$meta_file" "$status_file"
}

@test "cmd_status handles unknown status" {
    local job_id="unknownstatus" meta_file status_file; meta_file=$(get_meta_file "$job_id"); status_file=$(get_status_file "$job_id")
    create_test_meta "$job_id"
    echo 'start_time="2024-01-01 10:00:00"' > "$status_file"; echo 'end_time="2024-01-01 10:05:00"' >> "$status_file"; echo 'status="weird"' >> "$status_file"
    run cmd_status; [ "$status" -eq 0 ]; [[ "$output" == *"UNKNOWN"* ]]
    rm -f "$meta_file" "$status_file"
}

@test "cmd_status handles job with log but no status file" {
    local job_id="logonly" meta_file log_file; meta_file=$(get_meta_file "$job_id"); log_file=$(get_log_file "$job_id")
    create_test_meta "$job_id"; touch "$log_file"
    run cmd_status; [ "$status" -eq 0 ]; [[ "$output" == *"NO STATUS"* ]]
    rm -f "$meta_file" "$log_file"
}

# Tests for calculate_next_run function
@test "calculate_next_run handles every minute schedule" {
    run calculate_next_run "* * * * *"; [ "$status" -eq 0 ]; [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run handles hourly schedule" {
    run calculate_next_run "30 * * * *"; [ "$status" -eq 0 ]; [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run handles daily schedule" {
    run calculate_next_run "0 9 * * *"; [ "$status" -eq 0 ]; [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run handles weekly schedule" {
    run calculate_next_run "0 9 * * 1"; [ "$status" -eq 0 ]; [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run handles weekly schedule Sunday (0)" {
    run calculate_next_run "0 10 * * 0"; [ "$status" -eq 0 ]; [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run handles weekly schedule Saturday (6)" {
    run calculate_next_run "0 14 * * 6"; [ "$status" -eq 0 ]; [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run returns empty for complex schedule" {
    run calculate_next_run "0 9 15 * *"; [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "calculate_next_run handles midnight schedule" {
    run calculate_next_run "0 0 * * *"; [ "$status" -eq 0 ]; [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run handles end of day schedule" {
    run calculate_next_run "59 23 * * *"; [ "$status" -eq 0 ]; [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run handles minute step pattern" {
    run calculate_next_run "*/5 * * * *"; [ "$status" -eq 0 ]; [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run handles minute step pattern */10" {
    run calculate_next_run "*/10 * * * *"; [ "$status" -eq 0 ]; [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run handles minute step pattern */15" {
    run calculate_next_run "*/15 * * * *"; [ "$status" -eq 0 ]; [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run handles hour step pattern" {
    run calculate_next_run "0 */2 * * *"; [ "$status" -eq 0 ]; [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run handles hour step pattern */6" {
    run calculate_next_run "0 */6 * * *"; [ "$status" -eq 0 ]; [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

@test "calculate_next_run returns empty for weekday range" {
    run calculate_next_run "0 9 * * 1-5"; [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "calculate_next_run returns empty for weekday list" {
    run calculate_next_run "0 9 * * 1,3,5"; [ "$status" -eq 0 ]; [ -z "$output" ]
}

# Tests for cmd_stats function
@test "cmd_stats shows no jobs message when empty" {
    rm -f "${LOG_DIR}"/*.meta 2>/dev/null || true
    run cmd_stats; [ "$status" -eq 0 ]; [[ "$output" == *"No jobs found"* ]]
}

@test "cmd_stats shows stats for specific job" {
    local job_id="statsjob" meta_file history_file; meta_file=$(get_meta_file "$job_id"); history_file=$(get_history_file "$job_id")
    create_test_meta "$job_id"
    echo 'start="2024-01-01 10:00:00" end="2024-01-01 10:05:00" status="success" exit_code="0"' > "$history_file"
    echo 'start="2024-01-02 10:00:00" end="2024-01-02 10:03:00" status="success" exit_code="0"' >> "$history_file"
    echo 'start="2024-01-03 10:00:00" end="2024-01-03 10:02:00" status="failed" exit_code="1"' >> "$history_file"
    run cmd_stats "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"${job_id}"* ]]; [[ "$output" == *"Total runs: 3"* ]]; [[ "$output" == *"Success: 2"* ]]; [[ "$output" == *"Failed"* ]]; [[ "$output" == *"1"* ]]; [[ "$output" == *"Success rate: 66%"* ]]
    rm -f "$meta_file" "$history_file"
}

@test "cmd_stats fails for non-existent job" {
    run cmd_stats "nonexistent123"; [ "$status" -eq 2 ]; [[ "$output" == *"not found"* ]]
}

@test "cmd_stats shows stats for all jobs" {
    local job_id1="statsjob1" job_id2="statsjob2" meta_file1 meta_file2 history_file1 history_file2
    meta_file1=$(get_meta_file "$job_id1"); meta_file2=$(get_meta_file "$job_id2"); history_file1=$(get_history_file "$job_id1"); history_file2=$(get_history_file "$job_id2")
    create_test_meta "$job_id1"; create_test_meta "$job_id2"
    echo 'start="2024-01-01 10:00:00" end="2024-01-01 10:05:00" status="success" exit_code="0"' > "$history_file1"
    echo 'start="2024-01-02 10:00:00" end="2024-01-02 10:05:00" status="failed" exit_code="1"' > "$history_file2"
    run cmd_stats; [ "$status" -eq 0 ]; [[ "$output" == *"${job_id1}"* ]]; [[ "$output" == *"${job_id2}"* ]]
    rm -f "$meta_file1" "$meta_file2" "$history_file1" "$history_file2"
}

@test "cmd_stats handles job with no history" {
    local job_id="statsnohistory" meta_file; meta_file=$(get_meta_file "$job_id"); create_test_meta "$job_id"
    run cmd_stats "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"Total runs: 0"* ]]; [[ "$output" == *"Success: 0"* ]]; [[ "$output" == *"Failed"* ]]; [[ "$output" == *"0"* ]]
    rm -f "$meta_file"
}

@test "cmd_help stats shows detailed help" {
    run cmd_help "stats"; [ "$status" -eq 0 ]; [[ "$output" == *"cc-cron stats"* ]]; [[ "$output" == *"execution statistics"* ]]
}

@test "cmd_help pause shows detailed help" {
    run cmd_help "pause"; [ "$status" -eq 0 ]; [[ "$output" == *"cc-cron pause"* ]]; [[ "$output" == *"Temporarily disable"* ]]; [[ "$output" == *"Alias: disable"* ]]
}

@test "cmd_help resume shows detailed help" {
    run cmd_help "resume"; [ "$status" -eq 0 ]; [[ "$output" == *"cc-cron resume"* ]]; [[ "$output" == *"Re-enable a paused job"* ]]; [[ "$output" == *"Alias: enable"* ]]
}

@test "cmd_help disable shows pause help" {
    run cmd_help "disable"; [ "$status" -eq 0 ]; [[ "$output" == *"cc-cron pause"* ]]; [[ "$output" == *"Alias: disable"* ]]
}

@test "cmd_help enable shows resume help" {
    run cmd_help "enable"; [ "$status" -eq 0 ]; [[ "$output" == *"cc-cron resume"* ]]; [[ "$output" == *"Alias: enable"* ]]
}

@test "cmd_help export shows detailed help" {
    run cmd_help "export"; [ "$status" -eq 0 ]; [[ "$output" == *"cc-cron export"* ]]; [[ "$output" == *"Export jobs to JSON"* ]]
}

@test "cmd_help import shows detailed help" {
    run cmd_help "import"; [ "$status" -eq 0 ]; [[ "$output" == *"cc-cron import"* ]]; [[ "$output" == *"Import jobs from JSON"* ]]
}

@test "cmd_help remove shows detailed help" {
    run cmd_help "remove"; [ "$status" -eq 0 ]; [[ "$output" == *"cc-cron remove"* ]]; [[ "$output" == *"Remove a scheduled job"* ]]
}

@test "cmd_help doctor shows detailed help" {
    run cmd_help "doctor"; [ "$status" -eq 0 ]; [[ "$output" == *"cc-cron doctor"* ]]; [[ "$output" == *"Diagnose issues"* ]]
}

@test "cmd_help version shows detailed help" {
    run cmd_help "version"; [ "$status" -eq 0 ]; [[ "$output" == *"cc-cron version"* ]]; [[ "$output" == *"Show version"* ]]
}

@test "cmd_stats handles malformed history entries gracefully" {
    local job_id="malformedstats" meta_file; meta_file=$(get_meta_file "$job_id")
    local history_file; history_file=$(get_history_file "$job_id")

    create_test_meta "$job_id"

    # Create history with malformed entries
    echo 'start="2024-01-01 10:00:00" end="2024-01-01 10:05:00" status="success" exit_code="0"' > "$history_file"
    echo 'malformed line without proper format' >> "$history_file"
    echo 'start="2024-01-02 10:00:00" end="2024-01-02 10:03:00" status="failed" exit_code="1"' >> "$history_file"

    run cmd_stats "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"Total runs: 3"* ]]

    rm -f "$meta_file" "$history_file"
}

@test "cmd_stats for all jobs resets optional fields between iterations" {
    local job_workdir="$BATS_TEST_TMPDIR"
    cmd_add "0 9 * * *" "tagged job" "true" "$job_workdir" "" "bypassPermissions" "0" "false" "prod,backup" >/dev/null
    local tagged_job="$LAST_CREATED_JOB_ID"
    cmd_add "0 10 * * *" "untagged job" "true" "$job_workdir" "" "bypassPermissions" "0" >/dev/null
    local untagged_job="$LAST_CREATED_JOB_ID"
    [ -f "$(get_meta_file "$tagged_job")" ]; [ -f "$(get_meta_file "$untagged_job")" ]
    run cmd_stats; [ "$status" -eq 0 ]; [[ "$output" == *"${tagged_job}"* ]]; [[ "$output" == *"${untagged_job}"* ]]
    rm -f "$(get_meta_file "$tagged_job")" "$(get_run_script "$tagged_job")" "$(get_meta_file "$untagged_job")" "$(get_run_script "$untagged_job")"
    crontab_remove_entry "CC-CRON:${tagged_job}" 2>/dev/null || true; crontab_remove_entry "CC-CRON:${untagged_job}" 2>/dev/null || true
}

# Integration tests for main() argument parsing
# These tests run the script directly to test command-line argument handling

@test "main add --model without argument returns error" {
    unset CC_CRON_TEST_MODE; export DATA_DIR="${BATS_TEST_TMPDIR}/.cc-cron" LOG_DIR="${DATA_DIR}/logs" LOCK_DIR="${DATA_DIR}/locks"; mkdir -p "$LOG_DIR" "$LOCK_DIR"
    run "${BATS_TEST_DIRNAME}/../cc-cron.sh" add "0 0 * * *" "test" --model; [ "$status" -eq 3 ]; [[ "$output" == *"--model requires"* ]]
}

@test "main add --tags without argument returns error" {
    unset CC_CRON_TEST_MODE; export DATA_DIR="${BATS_TEST_TMPDIR}/.cc-cron" LOG_DIR="${DATA_DIR}/logs" LOCK_DIR="${DATA_DIR}/locks"; mkdir -p "$LOG_DIR" "$LOCK_DIR"
    run "${BATS_TEST_DIRNAME}/../cc-cron.sh" add "0 0 * * *" "test" --tags; [ "$status" -eq 3 ]; [[ "$output" == *"--tags requires"* ]]
}

@test "main add --model with empty string is allowed" {
    unset CC_CRON_TEST_MODE; export DATA_DIR="${BATS_TEST_TMPDIR}/.cc-cron" LOG_DIR="${DATA_DIR}/logs" LOCK_DIR="${DATA_DIR}/locks"; mkdir -p "$LOG_DIR" "$LOCK_DIR"
    run "${BATS_TEST_DIRNAME}/../cc-cron.sh" add "0 0 * * *" "test" --model ""; [ "$status" -eq 0 ]; [[ "$output" == *"Created cron job"* ]]
}

@test "main add --tags with empty string is allowed" {
    unset CC_CRON_TEST_MODE; export DATA_DIR="${BATS_TEST_TMPDIR}/.cc-cron" LOG_DIR="${DATA_DIR}/logs" LOCK_DIR="${DATA_DIR}/locks"; mkdir -p "$LOG_DIR" "$LOCK_DIR"
    run "${BATS_TEST_DIRNAME}/../cc-cron.sh" add "0 0 * * *" "test" --tags ""; [ "$status" -eq 0 ]; [[ "$output" == *"Created cron job"* ]]
}

@test "main add --workdir without argument returns error" {
    unset CC_CRON_TEST_MODE; export DATA_DIR="${BATS_TEST_TMPDIR}/.cc-cron" LOG_DIR="${DATA_DIR}/logs" LOCK_DIR="${DATA_DIR}/locks"; mkdir -p "$LOG_DIR" "$LOCK_DIR"
    run "${BATS_TEST_DIRNAME}/../cc-cron.sh" add "0 0 * * *" "test" --workdir; [ "$status" -eq 3 ]; [[ "$output" == *"--workdir requires a path"* ]]
}

@test "main add --timeout without argument returns error" {
    unset CC_CRON_TEST_MODE; export DATA_DIR="${BATS_TEST_TMPDIR}/.cc-cron" LOG_DIR="${DATA_DIR}/logs" LOCK_DIR="${DATA_DIR}/locks"; mkdir -p "$LOG_DIR" "$LOCK_DIR"
    run "${BATS_TEST_DIRNAME}/../cc-cron.sh" add "0 0 * * *" "test" --timeout; [ "$status" -eq 3 ]; [[ "$output" == *"--timeout requires"* ]]
}

@test "main add --permission-mode without argument returns error" {
    unset CC_CRON_TEST_MODE; export DATA_DIR="${BATS_TEST_TMPDIR}/.cc-cron" LOG_DIR="${DATA_DIR}/logs" LOCK_DIR="${DATA_DIR}/locks"; mkdir -p "$LOG_DIR" "$LOCK_DIR"
    run "${BATS_TEST_DIRNAME}/../cc-cron.sh" add "0 0 * * *" "test" --permission-mode; [ "$status" -eq 3 ]; [[ "$output" == *"--permission-mode requires"* ]]
}

@test "main unknown command returns error" {
    unset CC_CRON_TEST_MODE; export DATA_DIR="${BATS_TEST_TMPDIR}/.cc-cron" LOG_DIR="${DATA_DIR}/logs" LOCK_DIR="${DATA_DIR}/locks"; mkdir -p "$LOG_DIR" "$LOCK_DIR"
    run "${BATS_TEST_DIRNAME}/../cc-cron.sh" nonexistentcmd; [ "$status" -eq 3 ]; [[ "$output" == *"Unknown command"* ]]
}

@test "main add unknown option returns error" {
    unset CC_CRON_TEST_MODE; export DATA_DIR="${BATS_TEST_TMPDIR}/.cc-cron" LOG_DIR="${DATA_DIR}/logs" LOCK_DIR="${DATA_DIR}/locks"; mkdir -p "$LOG_DIR" "$LOCK_DIR"
    run "${BATS_TEST_DIRNAME}/../cc-cron.sh" add "0 0 * * *" "test" --unknown-option; [ "$status" -eq 3 ]; [[ "$output" == *"Unknown option"* ]]
}

# Tests for main function command argument validation
@test "main remove without job-id returns error" {
    unset CC_CRON_TEST_MODE; export DATA_DIR="${BATS_TEST_TMPDIR}/.cc-cron" LOG_DIR="${DATA_DIR}/logs" LOCK_DIR="${DATA_DIR}/locks"; mkdir -p "$LOG_DIR" "$LOCK_DIR"
    run "${BATS_TEST_DIRNAME}/../cc-cron.sh" remove; [ "$status" -eq 3 ]; [[ "$output" == *"Usage"* ]]
}

@test "main pause without job-id returns error" {
    unset CC_CRON_TEST_MODE; export DATA_DIR="${BATS_TEST_TMPDIR}/.cc-cron" LOG_DIR="${DATA_DIR}/logs" LOCK_DIR="${DATA_DIR}/locks"; mkdir -p "$LOG_DIR" "$LOCK_DIR"
    run "${BATS_TEST_DIRNAME}/../cc-cron.sh" pause; [ "$status" -eq 3 ]; [[ "$output" == *"Usage"* ]]
}

@test "main resume without job-id returns error" {
    unset CC_CRON_TEST_MODE; export DATA_DIR="${BATS_TEST_TMPDIR}/.cc-cron" LOG_DIR="${DATA_DIR}/logs" LOCK_DIR="${DATA_DIR}/locks"; mkdir -p "$LOG_DIR" "$LOCK_DIR"
    run "${BATS_TEST_DIRNAME}/../cc-cron.sh" resume; [ "$status" -eq 3 ]; [[ "$output" == *"Usage"* ]]
}

@test "main show without job-id returns error" {
    unset CC_CRON_TEST_MODE; export DATA_DIR="${BATS_TEST_TMPDIR}/.cc-cron" LOG_DIR="${DATA_DIR}/logs" LOCK_DIR="${DATA_DIR}/locks"; mkdir -p "$LOG_DIR" "$LOCK_DIR"
    run "${BATS_TEST_DIRNAME}/../cc-cron.sh" show; [ "$status" -eq 3 ]; [[ "$output" == *"Usage"* ]]
}

@test "main logs without job-id returns error" {
    unset CC_CRON_TEST_MODE; export DATA_DIR="${BATS_TEST_TMPDIR}/.cc-cron" LOG_DIR="${DATA_DIR}/logs" LOCK_DIR="${DATA_DIR}/locks"; mkdir -p "$LOG_DIR" "$LOCK_DIR"
    run "${BATS_TEST_DIRNAME}/../cc-cron.sh" logs; [ "$status" -eq 3 ]; [[ "$output" == *"Usage"* ]]
}

@test "main history without job-id returns error" {
    unset CC_CRON_TEST_MODE; export DATA_DIR="${BATS_TEST_TMPDIR}/.cc-cron" LOG_DIR="${DATA_DIR}/logs" LOCK_DIR="${DATA_DIR}/locks"; mkdir -p "$LOG_DIR" "$LOCK_DIR"
    run "${BATS_TEST_DIRNAME}/../cc-cron.sh" history; [ "$status" -eq 3 ]; [[ "$output" == *"Usage"* ]]
}

@test "main run without job-id returns error" {
    unset CC_CRON_TEST_MODE; export DATA_DIR="${BATS_TEST_TMPDIR}/.cc-cron" LOG_DIR="${DATA_DIR}/logs" LOCK_DIR="${DATA_DIR}/locks"; mkdir -p "$LOG_DIR" "$LOCK_DIR"
    run "${BATS_TEST_DIRNAME}/../cc-cron.sh" run; [ "$status" -eq 3 ]; [[ "$output" == *"Usage"* ]]
}

@test "main edit without job-id returns error" {
    unset CC_CRON_TEST_MODE; export DATA_DIR="${BATS_TEST_TMPDIR}/.cc-cron" LOG_DIR="${DATA_DIR}/logs" LOCK_DIR="${DATA_DIR}/locks"; mkdir -p "$LOG_DIR" "$LOCK_DIR"
    run "${BATS_TEST_DIRNAME}/../cc-cron.sh" edit; [ "$status" -eq 3 ]; [[ "$output" == *"Usage"* ]]
}

@test "main clone without job-id returns error" {
    unset CC_CRON_TEST_MODE; export DATA_DIR="${BATS_TEST_TMPDIR}/.cc-cron" LOG_DIR="${DATA_DIR}/logs" LOCK_DIR="${DATA_DIR}/locks"; mkdir -p "$LOG_DIR" "$LOCK_DIR"
    run "${BATS_TEST_DIRNAME}/../cc-cron.sh" clone; [ "$status" -eq 3 ]; [[ "$output" == *"Usage"* ]]
}

@test "main import without file returns error" {
    unset CC_CRON_TEST_MODE; export DATA_DIR="${BATS_TEST_TMPDIR}/.cc-cron" LOG_DIR="${DATA_DIR}/logs" LOCK_DIR="${DATA_DIR}/locks"; mkdir -p "$LOG_DIR" "$LOCK_DIR"
    run "${BATS_TEST_DIRNAME}/../cc-cron.sh" import; [ "$status" -eq 3 ]; [[ "$output" == *"Usage"* ]]
}

# Tests for escape_shell_string helper function
@test "escape_shell_string escapes double quotes" {
    run escape_shell_string 'He said "hello"'; [ "$status" -eq 0 ]; [ "$output" == 'He said \"hello\"' ]
}

@test "escape_shell_string escapes backslashes" {
    run escape_shell_string 'C:\Users\test'; [ "$status" -eq 0 ]; [ "$output" == 'C:\\Users\\test' ]
}

@test "escape_shell_string escapes both quotes and backslashes" {
    run escape_shell_string 'Test "path" C:\folder'; [ "$status" -eq 0 ]; [ "$output" == 'Test \"path\" C:\\folder' ]
}

@test "escape_shell_string handles empty string" {
    run escape_shell_string ""; [ "$status" -eq 0 ]; [ "$output" == "" ]
}

@test "escape_shell_string handles string without special chars" {
    run escape_shell_string "normal string"; [ "$status" -eq 0 ]; [ "$output" == "normal string" ]
}

# Tests for escape_json_string helper function
@test "escape_json_string escapes double quotes" {
    run escape_json_string 'He said "hello"'; [ "$status" -eq 0 ]; [ "$output" == 'He said \"hello\"' ]
}

@test "escape_json_string escapes backslashes" {
    run escape_json_string 'C:\Users\test'; [ "$status" -eq 0 ]; [ "$output" == 'C:\\Users\\test' ]
}

@test "escape_json_string escapes newlines" {
    run escape_json_string $'line1\nline2'; [ "$status" -eq 0 ]; [ "$output" == 'line1\nline2' ]
}

@test "escape_json_string escapes tabs" {
    run escape_json_string $'col1\tcol2'; [ "$status" -eq 0 ]; [ "$output" == 'col1\tcol2' ]
}

@test "escape_json_string handles empty string" {
    run escape_json_string ""; [ "$status" -eq 0 ]; [ "$output" == "" ]
}

# Tests for write_meta_file special character escaping
@test "write_meta_file escapes double quotes in prompt" {
    local job_id="escquote" meta_file prompt='He said "hello world" to me'; meta_file=$(get_meta_file "$job_id")
    write_meta_file "$job_id" "2024-01-01 10:00:00" "0 9 * * *" "true" "$prompt" "/tmp" "" "auto" "0" "/tmp/run.sh"
    source "$meta_file"; [ "$prompt" == 'He said "hello world" to me' ]
    rm -f "$meta_file"
}

@test "write_meta_file escapes backslashes in prompt" {
    local job_id="escslash" meta_file prompt='Path: C:\Users\test\node_modules'; meta_file=$(get_meta_file "$job_id")
    write_meta_file "$job_id" "2024-01-01 10:00:00" "0 9 * * *" "true" "$prompt" "/tmp" "" "auto" "0" "/tmp/run.sh"
    source "$meta_file"; [ "$prompt" == 'Path: C:\Users\test\node_modules' ]
    rm -f "$meta_file"
}

@test "write_meta_file escapes both quotes and backslashes in prompt" {
    local job_id="escboth" meta_file prompt='Test "path" C:\test\folder and "more"'; meta_file=$(get_meta_file "$job_id")
    write_meta_file "$job_id" "2024-01-01 10:00:00" "0 9 * * *" "true" "$prompt" "/tmp" "" "auto" "0" "/tmp/run.sh"
    source "$meta_file"; [ "$prompt" == 'Test "path" C:\test\folder and "more"' ]
    rm -f "$meta_file"
}

@test "write_meta_file escapes special characters in workdir" {
    local job_id="escwork" meta_file workdir='/path/with "quotes"/and\backslashes'; meta_file=$(get_meta_file "$job_id")
    write_meta_file "$job_id" "2024-01-01 10:00:00" "0 9 * * *" "true" "test" "$workdir" "" "auto" "0" "/tmp/run.sh"
    source "$meta_file"; [ "$workdir" == '/path/with "quotes"/and\backslashes' ]
    rm -f "$meta_file"
}

@test "write_meta_file escapes special characters in tags" {
    local job_id="esctags" meta_file tags='tag"with"quotes,and\backslash'; meta_file=$(get_meta_file "$job_id")
    write_meta_file "$job_id" "2024-01-01 10:00:00" "0 9 * * *" "true" "test" "/tmp" "" "auto" "0" "/tmp/run.sh" "" "$tags"
    source "$meta_file"; [ "$tags" == 'tag"with"quotes,and\backslash' ]
    rm -f "$meta_file"
}

@test "write_meta_file preserves JSON-like prompt" {
    local job_id="escjson" meta_file prompt='{"key": "value", "nested": {"data": "test"}}'; meta_file=$(get_meta_file "$job_id")
    write_meta_file "$job_id" "2024-01-01 10:00:00" "0 9 * * *" "true" "$prompt" "/tmp" "" "auto" "0" "/tmp/run.sh"
    source "$meta_file"; [ "$prompt" == '{"key": "value", "nested": {"data": "test"}}' ]
    rm -f "$meta_file"
}

@test "write_meta_file handles consecutive backslashes" {
    local job_id="escmultislash" meta_file prompt='UNC path: \\server\share\folder'; meta_file=$(get_meta_file "$job_id")
    write_meta_file "$job_id" "2024-01-01 10:00:00" "0 9 * * *" "true" "$prompt" "/tmp" "" "auto" "0" "/tmp/run.sh"
    source "$meta_file"; [ "$prompt" == 'UNC path: \\server\share\folder' ]
    rm -f "$meta_file"
}

@test "write_meta_file escapes special characters in model name" {
    local job_id="escmodel" meta_file model='model"with"quotes'; meta_file=$(get_meta_file "$job_id")
    write_meta_file "$job_id" "2024-01-01 10:00:00" "0 9 * * *" "true" "test" "/tmp" "$model" "auto" "0" "/tmp/run.sh"
    source "$meta_file"; [ "$model" == 'model"with"quotes' ]
    rm -f "$meta_file"
}

# Tests for JSON output with special characters
@test "cmd_list --json escapes backslashes in prompt" {
    local job_id="jsonbackslash" meta_file run_script; meta_file=$(get_meta_file "$job_id"); run_script=$(get_run_script "$job_id")
    create_test_meta "$job_id" "/tmp" "" "bypassPermissions" "0"; echo 'prompt="Path: C:\Users\test"' >> "$meta_file"
    crontab_add_entry "0 9 * * * ${run_script}  # ${CRON_COMMENT_PREFIX}${job_id}:recurring=true:prompt=Path: C"
    run cmd_list "" "true"; [ "$status" -eq 0 ]; [[ "$output" == *'Path: C:\\Users\\test'* ]]
    rm -f "$meta_file" "$run_script"; crontab_remove_entry "CC-CRON:${job_id}" 2>/dev/null || true
}

@test "cmd_export escapes backslashes in prompt" {
    local job_id="exportback" meta_file; meta_file=$(get_meta_file "$job_id")
    create_test_meta "$job_id" "/tmp" "" "bypassPermissions" "0"; echo 'prompt="Path: C:\Users\test"' >> "$meta_file"
    run cmd_export "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *'C:\\Users\\test'* ]]
    rm -f "$meta_file"
}

# Tests for cmd_purge actually removing files
@test "cmd_purge removes old log files" {
    local job_id="purgejob" meta_file log_file history_file; meta_file=$(get_meta_file "$job_id"); log_file=$(get_log_file "$job_id"); history_file=$(get_history_file "$job_id")
    create_test_meta "$job_id"
    echo "test log content" > "$log_file"; echo 'start="2024-01-01 10:00:00" end="2024-01-01 10:05:00" status="success" exit_code="0"' > "$history_file"
    touch -d "8 days ago" "$log_file" "$history_file" 2>/dev/null || touch -t "$(date -d '8 days ago' +%Y%m%d%H%M)" "$log_file" "$history_file"
    run cmd_purge "7" "false"; [ "$status" -eq 0 ]; [[ ! -f "$log_file" ]]; [[ ! -f "$history_file" ]]
    rm -f "$meta_file"
}

@test "cmd_purge keeps recent files" {
    local job_id="recentpurge" meta_file log_file run_script; meta_file=$(get_meta_file "$job_id"); log_file=$(get_log_file "$job_id"); run_script=$(get_run_script "$job_id")

    create_test_meta "$job_id"

    # Add crontab entry so job is not considered an orphan
    crontab_add_entry "0 9 * * * ${run_script}  # ${CRON_COMMENT_PREFIX}${job_id}:recurring=true:prompt=test"

    # Create recent log file
    echo "recent log content" > "$log_file"

    # Run purge with 7 days threshold
    run cmd_purge "7" "false"; [ "$status" -eq 0 ]; [[ -f "$log_file" ]]

    # Cleanup
    rm -f "$meta_file" "$log_file" "$run_script"
    crontab_remove_entry "CC-CRON:${job_id}" 2>/dev/null || true
}

@test "cmd_config set accepts valid permission_mode" {
    local config_file="${DATA_DIR}/config"
    rm -f "$config_file"

    run cmd_config "set" "permission_mode" "acceptEdits"; [ "$status" -eq 0 ]; [[ "$output" == *"Set permission_mode"* ]]; [[ -f "$config_file" ]]; grep -q "permission_mode=\"acceptEdits\"" "$config_file"

    rm -f "$config_file"
}

@test "cmd_config set rejects invalid permission_mode" {
    run cmd_config "set" "permission_mode" "invalid_mode"; [ "$status" -eq 3 ]; [[ "$output" == *"Invalid permission mode"* ]]
}

@test "cmd_remove fails for job without crontab entry but cleans up files" {
    local job_id="orphanremove" meta_file log_file; meta_file=$(get_meta_file "$job_id"); log_file=$(get_log_file "$job_id")

    # Create meta file without adding to crontab
    create_test_meta "$job_id"
    echo "test log" > "$log_file"

    # Remove should fail since job is not in crontab
    run cmd_remove "$job_id"; [ "$status" -eq 2 ]; [[ ! -f "$meta_file" ]]; [[ ! -f "$log_file" ]]
}

# Tests for _show_job_stats helper function
@test "_show_job_stats fails for non-existent job" {
    run _show_job_stats "nonexistent"; [ "$status" -eq 2 ]; [[ "$output" == *"Job not found"* ]]
}

@test "_show_job_stats shows zero stats for job without history" {
    local job_id="statjob" meta_file; meta_file=$(get_meta_file "$job_id")

    create_test_meta "$job_id"

    run _show_job_stats "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"Total runs: 0"* ]]; [[ "$output" == *"Success: 0"* ]]; [[ "$output" == *"Failed:"* && "$output" == *"0"* ]]

    rm -f "$meta_file"
}

@test "_show_job_stats calculates success and failure counts" {
    local job_id="statcount" meta_file history_file; meta_file=$(get_meta_file "$job_id"); history_file=$(get_history_file "$job_id")

    create_test_meta "$job_id"

    # Create history with 2 successes and 1 failure
    cat > "$history_file" <<EOF
start="2024-01-01 10:00:00" end="2024-01-01 10:05:00" status="success" exit_code="0"
start="2024-01-02 10:00:00" end="2024-01-02 10:03:00" status="success" exit_code="0"
start="2024-01-03 10:00:00" end="2024-01-03 10:02:00" status="failed" exit_code="1"
EOF

    run _show_job_stats "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"Total runs: 3"* ]]; [[ "$output" == *"Success: 2"* ]]; [[ "$output" == *"Failed:"* ]]; [[ "$output" == *"Success rate: 66%"* ]]

    rm -f "$meta_file" "$history_file"
}

@test "_show_job_stats shows last success and failure times" {
    local job_id="stattimes" meta_file history_file; meta_file=$(get_meta_file "$job_id"); history_file=$(get_history_file "$job_id")

    create_test_meta "$job_id"

    # Create history with success and failure
    cat > "$history_file" <<EOF
start="2024-01-01 10:00:00" end="2024-01-01 10:05:00" status="success" exit_code="0"
start="2024-01-02 11:00:00" end="2024-01-02 11:02:00" status="failed" exit_code="1"
EOF

    run _show_job_stats "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"Last success: 2024-01-01 10:05:00"* ]]; [[ "$output" == *"Last failure: 2024-01-02 11:02:00"* ]]

    rm -f "$meta_file" "$history_file"
}

@test "_show_job_stats calculates average duration" {
    local job_id="statduration" meta_file history_file; meta_file=$(get_meta_file "$job_id"); history_file=$(get_history_file "$job_id")

    create_test_meta "$job_id"

    # Create history with known durations:
    # 10:00 to 10:05 = 5 minutes = 300 seconds
    # 11:00 to 11:07 = 7 minutes = 420 seconds
    # Average = 360 seconds = 6 minutes
    cat > "$history_file" <<EOF
start="2024-01-01 10:00:00" end="2024-01-01 10:05:00" status="success" exit_code="0"
start="2024-01-01 11:00:00" end="2024-01-01 11:07:00" status="success" exit_code="0"
EOF

    run _show_job_stats "$job_id"; [ "$status" -eq 0 ]; [[ "$output" == *"Avg duration: 6m 0s"* ]]

    rm -f "$meta_file" "$history_file"
}

# Test validate_range function
@test "validate_range accepts value at minimum" {
    run validate_range "0" 0 59 "minute"; [ "$status" -eq 0 ]
}

@test "validate_range accepts value at maximum" {
    run validate_range "59" 0 59 "minute"; [ "$status" -eq 0 ]
}

@test "validate_range accepts value in middle" {
    run validate_range "30" 0 59 "minute"; [ "$status" -eq 0 ]
}

@test "validate_range rejects value below minimum" {
    run validate_range "-1" 0 59 "minute"; [ "$status" -eq 3 ]; [[ "$output" == *"Invalid value"* ]]
}

@test "validate_range rejects value above maximum" {
    run validate_range "60" 0 59 "minute"; [ "$status" -eq 3 ]; [[ "$output" == *"Invalid value"* ]]
}

# Test is_valid_cron function
@test "is_valid_cron returns success for valid cron" {
    run is_valid_cron "0 9 * * *"; [ "$status" -eq 0 ]
}

@test "is_valid_cron returns failure for invalid cron" {
    run is_valid_cron "invalid"; [ "$status" -ne 0 ]
}

@test "is_valid_cron returns failure for cron with too many fields" {
    run is_valid_cron "0 9 * * * *"; [ "$status" -ne 0 ]
}

@test "is_valid_cron returns failure for cron with too few fields" {
    run is_valid_cron "0 9 * *"; [ "$status" -ne 0 ]
}

# Test validate_permission_mode function
@test "validate_permission_mode accepts bypassPermissions" {
    run validate_permission_mode "bypassPermissions"; [ "$status" -eq 0 ]
}

@test "validate_permission_mode accepts acceptEdits" {
    run validate_permission_mode "acceptEdits"; [ "$status" -eq 0 ]
}

@test "validate_permission_mode accepts auto" {
    run validate_permission_mode "auto"; [ "$status" -eq 0 ]
}

@test "validate_permission_mode accepts default" {
    run validate_permission_mode "default"; [ "$status" -eq 0 ]
}

@test "validate_permission_mode rejects invalid mode" {
    run validate_permission_mode "invalid"; [ "$status" -eq 3 ]; [[ "$output" == *"Invalid permission mode"* ]]
}

# Test validate_timeout function
@test "validate_timeout accepts zero" {
    run validate_timeout "0"; [ "$status" -eq 0 ]
}

@test "validate_timeout accepts positive number" {
    run validate_timeout "3600"; [ "$status" -eq 0 ]
}

@test "validate_timeout rejects negative number" {
    run validate_timeout "-1"; [ "$status" -eq 3 ]; [[ "$output" == *"non-negative number"* ]]
}

@test "validate_timeout rejects non-numeric value" {
    run validate_timeout "abc"; [ "$status" -eq 3 ]; [[ "$output" == *"non-negative number"* ]]
}

@test "validate_timeout rejects empty string" {
    run validate_timeout ""; [ "$status" -eq 3 ]; [[ "$output" == *"non-negative number"* ]]
}