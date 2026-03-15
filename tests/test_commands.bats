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