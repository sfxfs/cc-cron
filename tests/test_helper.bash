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

# Extract and source functions from script
load_script_functions() {
    # Source the script functions without running main
    source "${BATS_TEST_DIRNAME}/../cc-cron.sh" --source-only 2>/dev/null || true
}

# Create a test meta file with default values
# Usage: create_test_meta <job_id> [workdir] [model] [permission_mode] [timeout]
create_test_meta() {
    local job_id="$1"
    local workdir="${2:-/tmp}"
    local model="${3:-}"
    local permission="${4:-bypassPermissions}"
    local timeout="${5:-0}"

    local meta_file; meta_file=$(get_meta_file "$job_id")

    {
        echo "id=\"${job_id}\""
        echo "created=\"2024-01-01 10:00:00\""
        echo "cron=\"0 9 * * *\""
        echo "recurring=\"true\""
        echo "prompt=\"test prompt\""
        echo "workdir=\"${workdir}\""
        echo "model=\"${model}\""
        echo "permission_mode=\"${permission}\""
        echo "timeout=\"${timeout}\""
        echo "run_script=\"\${DATA_DIR}/run-${job_id}.sh\""
    } > "$meta_file"
}