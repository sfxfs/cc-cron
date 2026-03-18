# tests/test_helper.bash
# Test helper functions for cc-cron BATS tests

# Setup test environment
setup_test_env() {
    export CC_CRON_TEST_MODE=1
    export DATA_DIR="${BATS_TEST_TMPDIR}/.cc-cron"
    export LOG_DIR="${DATA_DIR}/logs"
    export LOCK_DIR="${DATA_DIR}/locks"
    mkdir -p "$LOG_DIR" "$LOCK_DIR"
}

# Cleanup test environment
teardown_test_env() {
    [[ -d "${DATA_DIR:-}" ]] && rm -rf "$DATA_DIR"
}

# Create a test meta file with default values
# Usage: create_test_meta <job_id> [workdir] [model] [permission_mode] [timeout] [tags] [prompt]
create_test_meta() {
    local job_id="$1" workdir="${2:-/tmp}" model="${3:-}" permission="${4:-bypassPermissions}" timeout="${5:-0}" tags="${6:-}" prompt="${7:-test prompt}"

    local meta_file; meta_file=$(get_meta_file "$job_id")

    {
        echo "id=\"${job_id}\""
        echo "created=\"2024-01-01 10:00:00\""
        echo "cron=\"0 9 * * *\""
        echo "recurring=\"true\""
        echo "prompt=\"${prompt}\""
        echo "workdir=\"${workdir}\""
        echo "model=\"${model}\""
        echo "permission_mode=\"${permission}\""
        echo "timeout=\"${timeout}\""
        [[ -n "$tags" ]] && echo "tags=\"${tags}\""
        echo "run_script=\"\${DATA_DIR}/run-${job_id}.sh\""
    } > "$meta_file"
}

# Cleanup a test job's files and crontab entry
# Usage: cleanup_test_job <job_id> [include_paused]
cleanup_test_job() {
    local job_id="$1" include_paused="${2:-false}"; rm -f "$(get_meta_file "$job_id")" "$(get_run_script "$job_id")" 2>/dev/null || true
    crontab_remove_entry "CC-CRON:${job_id}" 2>/dev/null || true
    [[ "$include_paused" == "true" ]] && rm -f "${DATA_DIR}/${job_id}.paused" 2>/dev/null || true
}

# Cleanup source and cloned job from clone tests
# Usage: cleanup_clone_test <source_id> <cloned_id>
cleanup_clone_test() {
    rm -f "$(get_meta_file "$1")" 2>/dev/null || true
    cleanup_test_job "$2"
}

# Create a test job with both meta file and crontab entry
# Usage: create_test_job <job_id> [workdir] [model] [permission_mode] [timeout] [tags]
create_test_job() {
    local job_id="$1" workdir="${2:-/tmp}" model="${3:-}" permission="${4:-bypassPermissions}" timeout="${5:-0}" tags="${6:-}"
    create_test_meta "$job_id" "$workdir" "$model" "$permission" "$timeout" "$tags"
    crontab_add_entry "0 9 * * * /tmp/run.sh  # CC-CRON:${job_id}:recurring=true" 2>/dev/null || true
}