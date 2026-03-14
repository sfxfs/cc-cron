# tests/test_commands.bats
#!/usr/bin/env bats

load 'test_helper'

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

@test "get_meta_file returns correct path" {
    source "${BATS_TEST_DIRNAME}/../cc-cron.sh" --source-only 2>/dev/null || true
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
    ensure_data_dir
    [ -d "$LOG_DIR" ]
    [ -d "$LOCK_DIR" ]
}