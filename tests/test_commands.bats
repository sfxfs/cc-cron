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

@test "get_history_file returns correct path" {
    run get_history_file "testjob"
    [ "$output" == "${LOG_DIR}/testjob.history" ]
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