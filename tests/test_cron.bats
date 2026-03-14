# tests/test_cron.bats
#!/usr/bin/env bats

load 'test_helper'

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

@test "validate_cron_field accepts wildcard" {
    source "${BATS_TEST_DIRNAME}/../cc-cron.sh" --source-only 2>/dev/null || true
    run validate_cron_field "*" 0 59 "minute"
    [ "$status" -eq 0 ]
}

@test "validate_cron_field accepts valid number" {
    run validate_cron_field "30" 0 59 "minute"
    [ "$status" -eq 0 ]
}

@test "validate_cron_field rejects out of range" {
    run validate_cron_field "60" 0 59 "minute"
    [ "$status" -ne 0 ]
}

@test "validate_cron_field accepts step values" {
    run validate_cron_field "*/5" 0 59 "minute"
    [ "$status" -eq 0 ]
}

@test "validate_cron_field accepts ranges" {
    run validate_cron_field "1-5" 0 6 "weekday"
    [ "$status" -eq 0 ]
}

@test "validate_cron_field accepts comma-separated lists" {
    run validate_cron_field "1,3,5" 0 6 "weekday"
    [ "$status" -eq 0 ]
}

@test "validate_cron accepts valid expression" {
    run validate_cron "0 9 * * 1-5"
    [ "$status" -eq 0 ]
}

@test "validate_cron rejects invalid expression" {
    run validate_cron "0 9 * *"
    [ "$status" -ne 0 ]
}