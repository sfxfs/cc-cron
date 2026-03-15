# tests/test_cron.bats
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

@test "validate_cron_field accepts wildcard" {
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

@test "validate_cron_field rejects negative numbers" {
    run validate_cron_field "-1" 0 59 "minute"
    [ "$status" -ne 0 ]
}

@test "validate_cron_field rejects non-numeric" {
    run validate_cron_field "abc" 0 59 "minute"
    [ "$status" -ne 0 ]
}

@test "validate_range accepts boundary values" {
    run validate_range 0 0 100 "test"
    [ "$status" -eq 0 ]
    run validate_range 100 0 100 "test"
    [ "$status" -eq 0 ]
}

@test "validate_range rejects outside boundaries" {
    run validate_range -1 0 100 "test"
    [ "$status" -ne 0 ]
    run validate_range 101 0 100 "test"
    [ "$status" -ne 0 ]
}

@test "validate_cron_field rejects invalid step value" {
    run validate_cron_field "*/0" 0 59 "minute"
    [ "$status" -ne 0 ]
    run validate_cron_field "*/abc" 0 59 "minute"
    [ "$status" -ne 0 ]
}

@test "validate_cron_field rejects invalid range" {
    run validate_cron_field "5-2" 0 59 "minute"
    [ "$status" -ne 0 ]
    run validate_cron_field "a-b" 0 59 "minute"
    [ "$status" -ne 0 ]
}

@test "validate_cron_field accepts complex expressions" {
    run validate_cron_field "1-5,10,15-20" 0 59 "minute"
    [ "$status" -eq 0 ]
    run validate_cron_field "*/5,30" 0 59 "minute"
    [ "$status" -eq 0 ]
}

@test "validate_cron accepts common schedules" {
    run validate_cron "0 * * * *"
    [ "$status" -eq 0 ]
    run validate_cron "*/5 * * * *"
    [ "$status" -eq 0 ]
    run validate_cron "0 9 * * 1-5"
    [ "$status" -eq 0 ]
    run validate_cron "0 0 1 1 *"
    [ "$status" -eq 0 ]
}

@test "validate_cron rejects wrong field count" {
    run validate_cron "* * * *"
    [ "$status" -ne 0 ]
    run validate_cron "* * * * * *"
    [ "$status" -ne 0 ]
}

@test "validate_permission_mode accepts valid modes" {
    run validate_permission_mode "bypassPermissions"
    [ "$status" -eq 0 ]
    run validate_permission_mode "acceptEdits"
    [ "$status" -eq 0 ]
    run validate_permission_mode "auto"
    [ "$status" -eq 0 ]
    run validate_permission_mode "default"
    [ "$status" -eq 0 ]
}

@test "validate_permission_mode rejects invalid mode" {
    run validate_permission_mode "invalid"
    [ "$status" -ne 0 ]
    run validate_permission_mode ""
    [ "$status" -ne 0 ]
}

@test "validate_timeout accepts valid values" {
    run validate_timeout "0"
    [ "$status" -eq 0 ]
    run validate_timeout "60"
    [ "$status" -eq 0 ]
    run validate_timeout "3600"
    [ "$status" -eq 0 ]
}

@test "validate_timeout rejects invalid values" {
    run validate_timeout "-1"
    [ "$status" -ne 0 ]
    run validate_timeout "abc"
    [ "$status" -ne 0 ]
    run validate_timeout ""
    [ "$status" -ne 0 ]
    run validate_timeout "1.5"
    [ "$status" -ne 0 ]
}