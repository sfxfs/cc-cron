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