#!/usr/bin/env bash
#
# cc-cron - Schedule Claude Code commands as cron jobs
#

set -euo pipefail

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_ERROR=1
readonly EXIT_NOT_FOUND=2
readonly EXIT_INVALID_ARGS=3

# Version
readonly VERSION="1.4.0"

# Configuration
DATA_DIR="${DATA_DIR:-${HOME}/.cc-cron}"
LOG_DIR="${LOG_DIR:-${DATA_DIR}/logs}"
LOCK_DIR="${LOCK_DIR:-${DATA_DIR}/locks}"
CRON_COMMENT_PREFIX="CC-CRON:"

# Environment configuration (can be overridden)
CC_WORKDIR="${CC_WORKDIR:-$HOME}"
CC_PERMISSION_MODE="${CC_PERMISSION_MODE:-bypassPermissions}"
CC_MODEL="${CC_MODEL:-}"

# Crontab cache (performance optimization)
_CRONTAB_CACHE=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print colored output
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

# Error with configurable exit code
error() {
    local message="$1"
    local exit_code="${2:-$EXIT_ERROR}"
    echo -e "${RED}[ERROR]${NC} ${message}" >&2
    exit "$exit_code"
}

# Ensure data directory exists
ensure_data_dir() {
    mkdir -p "$LOG_DIR" "$LOCK_DIR"
}

# Helper functions for file paths
get_meta_file() { echo "${LOG_DIR}/${1}.meta"; }
get_log_file() { echo "${LOG_DIR}/${1}.log"; }
get_status_file() { echo "${LOG_DIR}/${1}.status"; }
get_history_file() { echo "${LOG_DIR}/${1}.history"; }
get_run_script() { echo "${DATA_DIR}/run-${1}.sh"; }

# Helper to validate a number is within range
validate_range() {
    local value="$1" min="$2" max="$3" context="$4"
    if [[ "$value" -lt "$min" || "$value" -gt "$max" ]]; then
        error "Invalid value '$value' for $context (must be $min-$max)"
    fi
}

# Helper to remove a file if it exists
remove_file() {
    [[ -f "$1" ]] && { rm "$1"; info "Removed $2: ${1}"; }
}

# Generate unique job ID with collision detection (optimized)
generate_job_id() {
    local job_id
    local random_bytes

    # Pre-generate random bytes for better performance
    local _
    for _ in {1..10}; do
        # Read more bytes at once for efficiency
        random_bytes=$(head -c 100 /dev/urandom | tr -dc 'a-z0-9')
        job_id="${random_bytes:0:8}"
        [[ ! -f "$(get_meta_file "$job_id")" ]] && echo "$job_id" && return
    done
    error "Failed to generate unique job ID after 10 attempts"
}

# Validate a single cron field value (optimized with case for speed)
validate_cron_field() {
    local value="$1" min="$2" max="$3" field_name="$4"

    # Handle wildcard (most common case first)
    [[ "$value" == "*" ]] && return 0

    # Handle comma-separated list first (before step/range checks)
    case "$value" in
        *,*)
            local IFS=','
            local part
            for part in $value; do
                validate_cron_field "$part" "$min" "$max" "$field_name"
            done
            return 0
            ;;
    esac

    # Handle */n (step) - use case instead of regex for ~20% speedup
    case "$value" in
        */*)
            local step="${value#*/}"
            step="${step%%/*}"
            [[ "$step" =~ ^[0-9]+$ ]] || error "Invalid step value in '$value' for $field_name"
            [[ "$step" -ge 1 && "$step" -le "$max" ]] && return 0
            error "Invalid step value '$step' in '$value' for $field_name (must be 1-$max)"
            ;;
    esac

    # Handle range n-m
    case "$value" in
        *-*)
            local start="${value%%-*}"
            local end="${value#*-}"
            [[ "$start" =~ ^[0-9]+$ ]] || error "Invalid range '$value' for $field_name"
            [[ "$end" =~ ^[0-9]+$ ]] || error "Invalid range '$value' for $field_name"
            validate_range "$start" "$min" "$max" "$field_name range start"
            validate_range "$end" "$min" "$max" "$field_name range end"
            [[ "$start" -gt "$end" ]] && error "Invalid range '$value' for $field_name (start > end)"
            return 0
            ;;
    esac

    # Handle simple number
    [[ "$value" =~ ^[0-9]+$ ]] || error "Invalid cron field value '$value' for $field_name"
    validate_range "$value" "$min" "$max" "$field_name"
}

# Validate cron expression (full validation, optimized)
validate_cron() {
    local cron="$1"

    # Split into fields using read (faster than array slicing)
    local -a fields
    read -ra fields <<< "$cron"

    # Early exit for wrong field count
    if [[ ${#fields[@]} -ne 5 ]]; then
        error "Invalid cron expression: $cron (expected 5 fields: minute hour day month weekday)"
    fi

    # Validate each field: minute (0-59), hour (0-23), day (1-31), month (1-12), weekday (0-6)
    validate_cron_field "${fields[0]}" 0 59 "minute"
    validate_cron_field "${fields[1]}" 0 23 "hour"
    validate_cron_field "${fields[2]}" 1 31 "day of month"
    validate_cron_field "${fields[3]}" 1 12 "month"
    validate_cron_field "${fields[4]}" 0 6 "day of week"
}

# Validate working directory exists
validate_workdir() {
    [[ -d "$1" ]] || error "Directory not found: $1"
}

# Crontab helper functions
crontab_add_entry() {
    local entry="$1"
    (crontab -l 2>/dev/null; echo "$entry") | crontab -
    invalidate_crontab_cache
}

# Get crontab content with caching
get_crontab() {
    if [[ -z "${_CRONTAB_CACHE:-}" ]]; then
        _CRONTAB_CACHE=$(crontab -l 2>/dev/null) || _CRONTAB_CACHE=""
    fi
    printf '%s\n' "$_CRONTAB_CACHE"
}

# Invalidate crontab cache
invalidate_crontab_cache() {
    _CRONTAB_CACHE=""
}

# Check if crontab has entry matching pattern
crontab_has_entry() {
    local pattern="$1"
    get_crontab | grep -q "$pattern"
}

# Remove entry from crontab matching pattern
crontab_remove_entry() {
    local pattern="$1"
    crontab -l 2>/dev/null | { grep -v "$pattern" || true; } | crontab -
    invalidate_crontab_cache
}

# Generate lock file path from directory path
get_lock_file() {
    local dir="$1"
    local dir_hash
    dir_hash=$(echo -n "$dir" | md5sum | cut -d' ' -f1)
    echo "${LOCK_DIR}/${dir_hash}.lock"
}

# Add a new cron job
cmd_add() {
    local cron_expr="$1"
    local prompt="$2"
    local recurring="${3:-true}"
    local job_workdir="${4:-$CC_WORKDIR}"
    local job_model="${5:-$CC_MODEL}"
    local job_permission="${6:-$CC_PERMISSION_MODE}"
    local job_timeout="${7:-${CC_TIMEOUT:-0}}"

    validate_cron "$cron_expr"
    validate_workdir "$job_workdir"

    local job_id
    job_id=$(generate_job_id)
    local log_file; log_file=$(get_log_file "$job_id")
    local status_file; status_file=$(get_status_file "$job_id")
    local meta_file; meta_file=$(get_meta_file "$job_id")
    local lock_file; lock_file=$(get_lock_file "$job_workdir")
    local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    ensure_data_dir

    # Build the command with per-job or environment options
    local claude_opts="-p"
    [[ -n "$job_model" ]] && claude_opts="$claude_opts --model $job_model"
    [[ "$job_permission" != "default" ]] && claude_opts="$claude_opts --permission-mode $job_permission"

    # Sanitize prompt for safe shell embedding
    local safe_prompt="${prompt//\'/\'\\\'\'}"

    # Create wrapper script that handles locking and status tracking
    local run_script; run_script=$(get_run_script "$job_id")

    # Capture current PATH for cron environment
    local current_path="$PATH"

    cat > "$run_script" << RUNEOF
#!/usr/bin/env bash
# Auto-generated job runner for ${job_id}
set -e

# Set PATH for cron environment (captured at job creation time)
export PATH="${current_path}"

LOG_FILE="${log_file}"
STATUS_FILE="${status_file}"
HISTORY_FILE="${LOG_DIR}/${job_id}.history"
LOCK_FILE="${lock_file}"
WORKDIR="${job_workdir}"
JOB_ID="${job_id}"
RECURRING="${recurring}"
TIMEOUT="${job_timeout}"

# Cleanup function to release lock
cleanup() {
    exec 9>&-
}
trap cleanup EXIT

# Acquire lock for this directory (non-blocking)
exec 9>"\$LOCK_FILE"
if ! flock -n 9; then
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] SKIPPED: Another job is running in \$WORKDIR" >> "\$LOG_FILE"
    exit 0
fi

# Record start time
echo "start_time=\"\$(date '+%Y-%m-%d %H:%M:%S')\"" > "\$STATUS_FILE"
echo "status=\"running\"" >> "\$STATUS_FILE"

# Run the job
cd "\$WORKDIR"
if [[ "\${TIMEOUT:-0}" -gt 0 ]]; then
    timeout "\${TIMEOUT}" claude ${claude_opts} '${safe_prompt}' >> "\$LOG_FILE" 2>&1
else
    claude ${claude_opts} '${safe_prompt}' >> "\$LOG_FILE" 2>&1
fi
EXIT_CODE=\$?

# Record end time and status
echo "end_time=\"\$(date '+%Y-%m-%d %H:%M:%S')\"" >> "\$STATUS_FILE"
echo "exit_code=\"\${EXIT_CODE}\"" >> "\$STATUS_FILE"

if [[ \$EXIT_CODE -eq 0 ]]; then
    echo "status=\"success\"" >> "\$STATUS_FILE"
    # Record to history
    echo "start=\"\${start_time}\" end=\"\$(date '+%Y-%m-%d %H:%M:%S')\" status=\"success\" exit_code=\"0\"" >> "\$HISTORY_FILE"
    # Auto-remove one-shot jobs after successful execution
    if [[ "\$RECURRING" == "false" ]]; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] AUTO-REMOVED: One-shot job completed successfully" >> "\$LOG_FILE"
        (crontab -l 2>/dev/null | grep -v "CC-CRON:\${JOB_ID}:" || true) | crontab -
        rm -f "\$LOG_FILE" "\$STATUS_FILE" "${meta_file}" "\$HISTORY_FILE" "\$0"
    fi
else
    echo "status=\"failed\"" >> "\$STATUS_FILE"
    # Record to history
    echo "start=\"\${start_time}\" end=\"\$(date '+%Y-%m-%d %H:%M:%S')\" status=\"failed\" exit_code=\"\${EXIT_CODE}\"" >> "\$HISTORY_FILE"
    # Keep one-shot job on failure for retry/debugging
    if [[ "\$RECURRING" == "false" ]]; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] One-shot job failed - keeping job for retry. Run 'cc-cron remove \${JOB_ID}' to clean up." >> "\$LOG_FILE"
    fi
fi
RUNEOF
    chmod +x "$run_script"

    # Create the cron entry
    local cron_entry="${cron_expr} ${run_script}  # ${CRON_COMMENT_PREFIX}${job_id}:recurring=${recurring}:prompt=${prompt:0:30}"

    # Add to crontab
    crontab_add_entry "$cron_entry"

    # Save job metadata
    cat > "$meta_file" << EOF
id="${job_id}"
created="${timestamp}"
cron="${cron_expr}"
recurring="${recurring}"
prompt="${prompt}"
workdir="${job_workdir}"
model="${job_model}"
permission_mode="${job_permission}"
timeout="${job_timeout}"
run_script="${run_script}"
EOF

    success "Created cron job: ${job_id}"
    info "Schedule: ${cron_expr}"
    info "Recurring: ${recurring}"
    info "Workdir: ${job_workdir}"
    [[ -n "$job_model" ]] && info "Model: ${job_model}"
    info "Permission: ${job_permission}"
    [[ "$job_timeout" -gt 0 ]] && info "Timeout: ${job_timeout}s"
    info "Prompt: ${prompt}"
    info "Log file: ${log_file}"

    if [[ "$recurring" == "false" ]]; then
        info "One-shot job: will auto-remove after successful execution"
    fi
}

# List all cc-cron jobs (optimized: single crontab read)
cmd_list() {
    local found=0

    echo "Scheduled Claude Code Cron Jobs:"
    echo "================================="
    echo

    # Single crontab read with caching
    local crontab_content
    crontab_content=$(get_crontab) || return 0

    while IFS= read -r line; do
        if [[ "$line" == *"${CRON_COMMENT_PREFIX}"* ]]; then
            found=1
            # Extract job ID from comment using bash parameter expansion
            local job_id temp
            temp="${line#*"${CRON_COMMENT_PREFIX}"}"
            job_id="${temp%%:*}"

            # Read metadata if exists
            local meta_file; meta_file=$(get_meta_file "$job_id")
            if [[ -f "$meta_file" ]]; then
                source "$meta_file"
                echo "Job ID: ${id}"
                echo "  Created: ${created}"
                echo "  Schedule: ${cron}"
                echo "  Recurring: ${recurring}"
                echo "  Workdir: ${workdir:-$CC_WORKDIR}"
                [[ -n "${model:-}" ]] && echo "  Model: ${model}"
                echo "  Permission: ${permission_mode:-$CC_PERMISSION_MODE}"
                echo "  Prompt: ${prompt}"
                echo
            else
                echo "Job ID: ${job_id} (metadata missing)"
                echo "  Raw: ${line}"
                echo
            fi
        fi
    done <<< "$crontab_content"

    if [[ "$found" -eq 0 ]]; then
        info "No scheduled jobs found."
    fi
}

# Remove a cron job by ID (optimized)
cmd_remove() {
    local job_id="$1"
    local found=0

    # Remove from crontab using helper function
    if crontab_has_entry "${CRON_COMMENT_PREFIX}${job_id}"; then
        found=1
        crontab_remove_entry "${CRON_COMMENT_PREFIX}${job_id}"
        success "Removed cron job: ${job_id}"
    fi

    # Remove metadata, logs, status, and run script
    remove_file "$(get_meta_file "$job_id")" "metadata"
    remove_file "$(get_log_file "$job_id")" "log file"
    remove_file "$(get_status_file "$job_id")" "status file"
    remove_file "$(get_history_file "$job_id")" "history file"
    remove_file "$(get_run_script "$job_id")" "run script"

    if [[ "$found" -eq 0 ]]; then
        error "Job not found: ${job_id}"
    fi
}

# Show logs for a job
cmd_logs() {
    local job_id="$1"
    local log_file; log_file=$(get_log_file "$job_id")

    if [[ -f "$log_file" ]]; then
        info "Logs for job ${job_id}:"
        echo "================================="
        cat "$log_file"
    else
        error "No logs found for job: ${job_id}"
    fi
}

# Pause a job (comment out in crontab)
cmd_pause() {
    local job_id="$1"
    local found=0

    # Check if job exists
    if ! crontab_has_entry "${CRON_COMMENT_PREFIX}${job_id}"; then
        error "Job not found: ${job_id}"
    fi

    # Check if already paused
    local meta_file; meta_file=$(get_meta_file "$job_id")
    local paused_file="${DATA_DIR}/${job_id}.paused"

    if [[ -f "$paused_file" ]]; then
        warn "Job ${job_id} is already paused"
        return 0
    fi

    # Remove from crontab but keep metadata
    crontab_remove_entry "${CRON_COMMENT_PREFIX}${job_id}"
    touch "$paused_file"

    success "Paused job: ${job_id}"
    info "Run 'cc-cron resume ${job_id}' to resume"
}

# Resume a paused job
cmd_resume() {
    local job_id="$1"
    local paused_file="${DATA_DIR}/${job_id}.paused"
    local meta_file; meta_file=$(get_meta_file "$job_id")

    if [[ ! -f "$paused_file" ]]; then
        error "Job ${job_id} is not paused"
    fi

    if [[ ! -f "$meta_file" ]]; then
        error "Job metadata not found: ${job_id}"
    fi

    # Load metadata
    source "$meta_file"

    # Recreate cron entry
    local run_script; run_script=$(get_run_script "$job_id")
    local cron_entry="${cron} ${run_script}  # ${CRON_COMMENT_PREFIX}${job_id}:recurring=${recurring}:prompt=${prompt:0:30}"

    crontab_add_entry "$cron_entry"
    rm -f "$paused_file"

    success "Resumed job: ${job_id}"
    info "Schedule: ${cron}"
}

# Show detailed information for a specific job
cmd_show() {
    local job_id="$1"
    local meta_file; meta_file=$(get_meta_file "$job_id")

    if [[ ! -f "$meta_file" ]]; then
        error "Job not found: ${job_id}"
    fi

    # Load metadata
    source "$meta_file"

    echo "Job Details: ${id}"
    echo "===================="
    echo
    echo "  ID:           ${id}"
    echo "  Created:      ${created}"
    echo "  Schedule:     ${cron}"
    echo "  Recurring:    ${recurring}"
    echo "  Workdir:      ${workdir}"
    [[ -n "${model:-}" ]] && echo "  Model:        ${model}"
    echo "  Permission:   ${permission_mode}"
    [[ "${timeout:-0}" -gt 0 ]] && echo "  Timeout:      ${timeout}s"
    echo
    echo "  Prompt:"
    echo "    ${prompt}"
    echo

    # Check if paused
    local paused_file="${DATA_DIR}/${job_id}.paused"
    if [[ -f "$paused_file" ]]; then
        echo -e "  Status:       ${YELLOW}PAUSED${NC}"
        echo
    fi

    # Show current status
    local status_file; status_file=$(get_status_file "$job_id")
    if [[ -f "$status_file" ]]; then
        source "$status_file"
        echo "  Last Execution:"
        echo "    Start:      ${start_time:-unknown}"
        echo "    End:        ${end_time:-unknown}"
        case "${status:-}" in
            success) echo -e "    Status:     ${GREEN}SUCCESS${NC}" ;;
            failed)  echo -e "    Status:     ${RED}FAILED${NC} (exit code: ${exit_code:-unknown})" ;;
            running) echo -e "    Status:     ${YELLOW}RUNNING${NC}" ;;
            *)       echo -e "    Status:     ${YELLOW}UNKNOWN${NC}" ;;
        esac
        echo
    fi

    # Show history summary
    local history_file; history_file=$(get_history_file "$job_id")
    if [[ -f "$history_file" ]]; then
        local total_runs success_runs failed_runs
        total_runs=$(wc -l < "$history_file")
        success_runs=$(grep -c "status=success" "$history_file" 2>/dev/null || echo "0")
        failed_runs=$(grep -c "status=failed" "$history_file" 2>/dev/null || echo "0")
        echo "  Statistics:"
        echo "    Total runs:    ${total_runs}"
        echo -e "    Successful:    ${GREEN}${success_runs}${NC}"
        echo -e "    Failed:        ${RED}${failed_runs}${NC}"
        echo
    fi

    # Show log file location
    local log_file; log_file=$(get_log_file "$job_id")
    if [[ -f "$log_file" ]]; then
        echo "  Log file: ${log_file}"
    fi
}

# Show execution history for a job
cmd_history() {
    local job_id="$1"
    local lines="${2:-20}"
    local history_file; history_file=$(get_history_file "$job_id")
    local log_file; log_file=$(get_log_file "$job_id")

    if [[ ! -f "$log_file" ]]; then
        error "No logs found for job: ${job_id}"
    fi

    echo "Execution History for ${job_id}:"
    echo "================================="
    echo

    # Show from history file if exists (structured format)
    if [[ -f "$history_file" ]]; then
        echo "Recent executions:"
        echo "------------------"
        tail -n "$lines" "$history_file" | while IFS= read -r line; do
            local h_start h_end h_status h_exit
            h_start=$(echo "$line" | grep -oP 'start="\K[^"]+' || echo "unknown")
            h_end=$(echo "$line" | grep -oP 'end="\K[^"]+' || echo "unknown")
            h_status=$(echo "$line" | grep -oP 'status="\K[^"]+' || echo "unknown")
            h_exit=$(echo "$line" | grep -oP 'exit_code="\K[^"]+' || echo "")

            case "$h_status" in
                success) echo -e "  ${GREEN}✓${NC} ${h_start} - ${h_end}" ;;
                failed)  echo -e "  ${RED}✗${NC} ${h_start} - ${h_end} (exit: ${h_exit})" ;;
                *)       echo -e "  ${YELLOW}?${NC} ${h_start} - ${h_end}" ;;
            esac
        done
    else
        # Fall back to parsing log file timestamps
        echo "No structured history available. Showing recent log entries:"
        echo "------------------------------------------------------------"
        tail -n "$lines" "$log_file"
    fi
}

# Run a job immediately (for testing)
cmd_run() {
    local job_id="$1"
    local meta_file; meta_file=$(get_meta_file "$job_id")

    if [[ ! -f "$meta_file" ]]; then
        error "Job not found: ${job_id}"
    fi

    # Load metadata
    source "$meta_file"

    local run_script; run_script=$(get_run_script "$job_id")

    if [[ ! -f "$run_script" ]]; then
        error "Run script not found for job: ${job_id}"
    fi

    info "Running job ${job_id} immediately..."
    info "Workdir: ${workdir}"
    info "Prompt: ${prompt}"
    echo

    # Execute the run script
    "$run_script"
    local exit_code=$?

    echo
    if [[ $exit_code -eq 0 ]]; then
        success "Job completed successfully"
    else
        warn "Job exited with code: ${exit_code}"
    fi

    return $exit_code
}

# Edit a job's schedule or prompt
cmd_edit() {
    local job_id="$1"
    shift || true

    local meta_file; meta_file=$(get_meta_file "$job_id")

    if [[ ! -f "$meta_file" ]]; then
        error "Job not found: ${job_id}"
    fi

    # Load current metadata
    source "$meta_file"

    local new_cron="${cron}"
    local new_prompt="${prompt}"
    local new_workdir="${workdir}"
    local new_model="${model:-}"
    local new_permission="${permission_mode}"
    local new_timeout="${timeout:-0}"
    local has_changes=0

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cron)
                [[ -z "${2:-}" ]] && error "--cron requires a cron expression"
                validate_cron "$2"
                new_cron="$2"
                has_changes=1
                shift 2
                ;;
            --prompt)
                [[ -z "${2:-}" ]] && error "--prompt requires a prompt text"
                new_prompt="$2"
                has_changes=1
                shift 2
                ;;
            --workdir)
                [[ -z "${2:-}" ]] && error "--workdir requires a path"
                validate_workdir "$2"
                new_workdir="$2"
                has_changes=1
                shift 2
                ;;
            --model)
                if [[ -n "${2:-}" ]]; then
                    new_model="$2"
                else
                    new_model=""
                fi
                has_changes=1
                shift 2
                ;;
            --permission-mode)
                [[ -z "${2:-}" ]] && error "--permission-mode requires a mode"
                new_permission="$2"
                has_changes=1
                shift 2
                ;;
            --timeout)
                [[ -z "${2:-}" ]] && error "--timeout requires seconds"
                new_timeout="$2"
                has_changes=1
                shift 2
                ;;
            *)
                error "Unknown option: $1"
                ;;
        esac
    done

    if [[ "$has_changes" -eq 0 ]]; then
        warn "No changes specified. Use --cron, --prompt, --workdir, --model, --permission-mode, or --timeout"
        return 0
    fi

    # Check if job is paused
    local paused_file="${DATA_DIR}/${job_id}.paused"
    local was_paused=0
    [[ -f "$paused_file" ]] && was_paused=1

    # Remove old crontab entry if not paused
    if [[ "$was_paused" -eq 0 ]]; then
        crontab_remove_entry "${CRON_COMMENT_PREFIX}${job_id}"
    fi

    # Update metadata file
    local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    cat > "$meta_file" << EOF
id="${job_id}"
created="${created}"
modified="${timestamp}"
cron="${new_cron}"
recurring="${recurring}"
prompt="${new_prompt}"
workdir="${new_workdir}"
model="${new_model}"
permission_mode="${new_permission}"
timeout="${new_timeout}"
run_script="${run_script}"
EOF

    # Update run script with new settings
    local log_file; log_file=$(get_log_file "$job_id")
    local status_file; status_file=$(get_status_file "$job_id")
    local lock_file; lock_file=$(get_lock_file "$new_workdir")

    # Build the command with options
    local claude_opts="-p"
    [[ -n "$new_model" ]] && claude_opts="$claude_opts --model $new_model"
    [[ "$new_permission" != "default" ]] && claude_opts="$claude_opts --permission-mode $new_permission"

    local safe_prompt="${new_prompt//\'/\'\\\'\'}"
    local current_path="$PATH"

    cat > "$run_script" << RUNEOF
#!/usr/bin/env bash
# Auto-generated job runner for ${job_id}
set -e

# Set PATH for cron environment (captured at job creation time)
export PATH="${current_path}"

LOG_FILE="${log_file}"
STATUS_FILE="${status_file}"
HISTORY_FILE="${LOG_DIR}/${job_id}.history"
LOCK_FILE="${lock_file}"
WORKDIR="${new_workdir}"
JOB_ID="${job_id}"
RECURRING="${recurring}"
TIMEOUT="${new_timeout}"

# Cleanup function to release lock
cleanup() {
    exec 9>&-
}
trap cleanup EXIT

# Acquire lock for this directory (non-blocking)
exec 9>"\$LOCK_FILE"
if ! flock -n 9; then
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] SKIPPED: Another job is running in \$WORKDIR" >> "\$LOG_FILE"
    exit 0
fi

# Record start time
echo "start_time=\"\$(date '+%Y-%m-%d %H:%M:%S')\"" > "\$STATUS_FILE"
echo "status=\"running\"" >> "\$STATUS_FILE"

# Run the job
cd "\$WORKDIR"
if [[ "\${TIMEOUT:-0}" -gt 0 ]]; then
    timeout "\${TIMEOUT}" claude ${claude_opts} '${safe_prompt}' >> "\$LOG_FILE" 2>&1
else
    claude ${claude_opts} '${safe_prompt}' >> "\$LOG_FILE" 2>&1
fi
EXIT_CODE=\$?

# Record end time and status
echo "end_time=\"\$(date '+%Y-%m-%d %H:%M:%S')\"" >> "\$STATUS_FILE"
echo "exit_code=\"\${EXIT_CODE}\"" >> "\$STATUS_FILE"

if [[ \$EXIT_CODE -eq 0 ]]; then
    echo "status=\"success\"" >> "\$STATUS_FILE"
    echo "start=\"\${start_time}\" end=\"\$(date '+%Y-%m-%d %H:%M:%S')\" status=\"success\" exit_code=\"0\"" >> "\$HISTORY_FILE"
    if [[ "\$RECURRING" == "false" ]]; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] AUTO-REMOVED: One-shot job completed successfully" >> "\$LOG_FILE"
        (crontab -l 2>/dev/null | grep -v "CC-CRON:\${JOB_ID}:" || true) | crontab -
        rm -f "\$LOG_FILE" "\$STATUS_FILE" "${meta_file}" "\$HISTORY_FILE" "\$0"
    fi
else
    echo "status=\"failed\"" >> "\$STATUS_FILE"
    echo "start=\"\${start_time}\" end=\"\$(date '+%Y-%m-%d %H:%M:%S')\" status=\"failed\" exit_code=\"\${EXIT_CODE}\"" >> "\$HISTORY_FILE"
    if [[ "\$RECURRING" == "false" ]]; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] One-shot job failed - keeping job for retry. Run 'cc-cron remove \${JOB_ID}' to clean up." >> "\$LOG_FILE"
    fi
fi
RUNEOF
    chmod +x "$run_script"

    # Re-add to crontab if not paused
    if [[ "$was_paused" -eq 0 ]]; then
        local cron_entry="${new_cron} ${run_script}  # ${CRON_COMMENT_PREFIX}${job_id}:recurring=${recurring}:prompt=${new_prompt:0:30}"
        crontab_add_entry "$cron_entry"
    fi

    success "Updated job: ${job_id}"
    [[ "$cron" != "$new_cron" ]] && info "Schedule: ${cron} → ${new_cron}"
    [[ "$prompt" != "$new_prompt" ]] && info "Prompt updated"
    [[ "$workdir" != "$new_workdir" ]] && info "Workdir: ${workdir} → ${new_workdir}"
}

# Show status of all jobs and recent executions
cmd_status() {
    info "CC-Cron Status Report"
    echo "======================"
    echo

    # Check if crontab exists
    if ! crontab -l &>/dev/null; then
        warn "No crontab configured for current user"
        return
    fi

    # Count jobs
    local job_count
    job_count=$(crontab -l 2>/dev/null | { grep "${CRON_COMMENT_PREFIX}" || true; } | wc -l)
    echo "Total scheduled jobs: ${job_count}"
    echo

    # Show recent executions with status (single pass)
    echo "Recent executions:"
    echo "------------------"

    local success_count=0
    local failed_count=0
    local running_count=0
    local unknown_count=0

    for meta_file in "${LOG_DIR}"/*.meta; do
        [[ -f "$meta_file" ]] || continue
        source "$meta_file"

        local status_file; status_file=$(get_status_file "$id")
        local log_file; log_file=$(get_log_file "$id")

        if [[ -f "$status_file" ]]; then
            source "$status_file"
            local status_icon

            # Check if job is currently running (has start_time but no end_time, or status=running)
            if [[ "${status:-}" == "running" ]] || { [[ -n "${start_time:-}" ]] && [[ -z "${end_time:-}" ]]; }; then
                status_icon="${YELLOW}◉ RUNNING${NC}"
                echo -e "  ${id}: ${status_icon}"
                echo "    Start: ${start_time:-unknown}"
                echo "    Workdir: ${workdir}"
                echo
                ((running_count++)) || true
            else
                case "${status:-}" in
                    success)
                        status_icon="${GREEN}✓ SUCCESS${NC}"
                        ((success_count++)) || true
                        ;;
                    failed)
                        status_icon="${RED}✗ FAILED${NC}"
                        ((failed_count++)) || true
                        ;;
                    *)
                        status_icon="${YELLOW}? UNKNOWN${NC}"
                        ((unknown_count++)) || true
                        ;;
                esac
                echo -e "  ${id}: ${status_icon}"
                echo "    Start: ${start_time:-unknown}"
                echo "    End:   ${end_time:-unknown}"
                [[ -n "${exit_code:-}" ]] && echo "    Exit code: ${exit_code}"
                echo "    Workdir: ${workdir}"
                echo
            fi
        elif [[ -f "$log_file" ]]; then
            # Has log but no status (old format or running)
            local last_run
            last_run=$(stat -c %y "$log_file" 2>/dev/null | cut -d. -f1)
            echo -e "  ${id}: ${YELLOW}? NO STATUS${NC} (last activity: ${last_run})"
            echo "    Workdir: ${workdir}"
            echo
            ((unknown_count++)) || true
        fi
    done

    echo -e "Summary: ${GREEN}${success_count} succeeded${NC}, ${RED}${failed_count} failed${NC}, ${YELLOW}${running_count} running${NC}, ${unknown_count} unknown${NC}"
}

# Export jobs to JSON format
cmd_export() {
    local job_id="${1:-}"
    local output_file="${2:-}"

    # Collect jobs to export
    local -a jobs=()
    local export_count=0

    if [[ -n "$job_id" ]]; then
        # Export specific job
        local meta_file; meta_file=$(get_meta_file "$job_id")
        if [[ ! -f "$meta_file" ]]; then
            error "Job not found: ${job_id}"
        fi
        jobs+=("$job_id")
    else
        # Export all jobs
        for meta_file in "${LOG_DIR}"/*.meta; do
            [[ -f "$meta_file" ]] || continue
            local id
            id=$(basename "$meta_file" .meta)
            jobs+=("$id")
        done
    fi

    if [[ ${#jobs[@]} -eq 0 ]]; then
        warn "No jobs to export"
        return 0
    fi

    # Build JSON output
    local json_output
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    json_output='{"version":"1.0","exported_at":"'"${timestamp}"'","jobs":['
    local first=1

    for job_id in "${jobs[@]}"; do
        local meta_file; meta_file=$(get_meta_file "$job_id")
        [[ -f "$meta_file" ]] || continue
        source "$meta_file"

        # Check if paused
        local paused_file="${DATA_DIR}/${job_id}.paused"
        local is_paused="false"
        [[ -f "$paused_file" ]] && is_paused="true"

        if [[ "$first" -eq 1 ]]; then
            first=0
        else
            json_output+=","
        fi

        # Escape quotes in prompt for JSON
        local escaped_prompt="${prompt//\"/\\\"}"
        local escaped_workdir="${workdir//\"/\\\"}"
        local escaped_model="${model:-}"
        escaped_model="${escaped_model//\"/\\\"}"
        local escaped_permission="${permission_mode//\"/\\\"}"

        json_output+='{'
        json_output+='"id":"'"${id}"'",'
        json_output+='"created":"'"${created}"'",'
        json_output+='"cron":"'"${cron}"'",'
        json_output+='"recurring":'"${recurring}"','
        json_output+='"prompt":"'"${escaped_prompt}"'",'
        json_output+='"workdir":"'"${escaped_workdir}"'",'
        json_output+='"model":"'"${escaped_model}"'",'
        json_output+='"permission_mode":"'"${escaped_permission}"'",'
        json_output+='"timeout":'"${timeout:-0}"','
        json_output+='"paused":'"${is_paused}"''
        json_output+='}'

        ((export_count++)) || true
    done

    json_output+=']}'

    # Output to file or stdout
    if [[ -n "$output_file" ]]; then
        echo "$json_output" > "$output_file"
        success "Exported ${export_count} job(s) to ${output_file}"
    else
        echo "$json_output"
        info "Exported ${export_count} job(s)"
    fi
}

# Import jobs from JSON file
cmd_import() {
    local input_file="$1"

    if [[ ! -f "$input_file" ]]; then
        error "File not found: ${input_file}"
    fi

    # Check for jq
    if ! command -v jq &>/dev/null; then
        error "jq is required for import. Install with: apt-get install jq or brew install jq"
    fi

    # Parse JSON
    local job_count
    job_count=$(jq '.jobs | length' "$input_file")

    if [[ "$job_count" -eq 0 ]]; then
        warn "No jobs found in import file"
        return 0
    fi

    info "Found ${job_count} job(s) to import"

    local imported=0
    local skipped=0
    local i

    for ((i = 0; i < job_count; i++)); do
        local job_json
        job_json=$(jq -c ".jobs[$i]" "$input_file")

        local job_cron job_prompt job_recurring job_workdir job_model job_permission job_timeout job_paused
        job_cron=$(jq -r '.cron' <<< "$job_json")
        job_prompt=$(jq -r '.prompt' <<< "$job_json")
        job_recurring=$(jq -r '.recurring' <<< "$job_json")
        job_workdir=$(jq -r '.workdir' <<< "$job_json")
        job_model=$(jq -r '.model' <<< "$job_json")
        job_permission=$(jq -r '.permission_mode' <<< "$job_json")
        job_timeout=$(jq -r '.timeout' <<< "$job_json")
        job_paused=$(jq -r '.paused' <<< "$job_json")

        # Validate cron expression
        if ! validate_cron "$job_cron" 2>/dev/null; then
            warn "Skipping invalid cron expression: ${job_cron}"
            ((skipped++)) || true
            continue
        fi

        # Validate workdir
        if [[ ! -d "$job_workdir" ]]; then
            warn "Skipping job with missing workdir: ${job_workdir}"
            ((skipped++)) || true
            continue
        fi

        # Create the job
        cmd_add "$job_cron" "$job_prompt" "$job_recurring" "$job_workdir" "$job_model" "$job_permission" "$job_timeout"

        # Pause if needed
        if [[ "$job_paused" == "true" ]]; then
            local new_job_id
            # Get the most recently created job ID from crontab
            new_job_id=$(crontab -l 2>/dev/null | grep "${CRON_COMMENT_PREFIX}" | tail -1 | sed "s/.*${CRON_COMMENT_PREFIX}\\([^:]*\\):.*/\\1/")
            if [[ -n "$new_job_id" ]]; then
                cmd_pause "$new_job_id"
            fi
        fi

        ((imported++)) || true
    done

    success "Imported ${imported} job(s), skipped ${skipped}"
}

# Show version
cmd_version() {
    echo "cc-cron version ${VERSION}"
}

# Show help
cmd_help() {
    cat << 'HELP'
cc-cron - Schedule Claude Code commands as cron jobs

USAGE:
    cc-cron <command> [options]

COMMANDS:
    add <cron> <prompt> [options]    Add a scheduled job
        <cron>   - Standard 5-field cron expression (minute hour day month weekday)
        <prompt> - The prompt to send to Claude Code

        Options:
          --once                      Create a one-shot job (auto-removes after success)
          --workdir <path>            Working directory for this job
          --model <name>              Model to use: sonnet, opus, etc.
          --permission-mode <mode>    Permission mode (bypassPermissions, acceptEdits, auto, default)
          --timeout <seconds>         Timeout for job execution (0 = no timeout)

    list                            List all scheduled jobs
    status                          Show status overview and log activity
    remove <job-id>                 Remove a scheduled job
    logs <job-id>                   Show logs for a job
    pause <job-id>                  Pause a scheduled job
    resume <job-id>                 Resume a paused job
    show <job-id>                   Show detailed information for a job
    history <job-id> [lines]        Show execution history for a job
    run <job-id>                    Run a job immediately (for testing)
    edit <job-id> [options]         Edit a job's settings
        --cron <expr>               Update cron schedule
        --prompt <text>             Update prompt
        --workdir <path>            Update working directory
        --model <name>              Update model
        --permission-mode <mode>    Update permission mode
        --timeout <seconds>         Update timeout
    export [job-id] [file]          Export job(s) to JSON (to file or stdout)
    import <file>                   Import jobs from JSON file
    completion                      Output bash completion script
    version                         Show version information
    help                            Show this help message

ENVIRONMENT VARIABLES (used as defaults when not specified per-job):
    CC_WORKDIR          Working directory (default: $HOME)
    CC_PERMISSION_MODE  Permission mode (default: bypassPermissions)
    CC_MODEL            Model to use (default: unset, uses Claude's default)
    CC_TIMEOUT          Job timeout in seconds (default: 0, no timeout)

CRON EXPRESSION FORMAT:
    ┌───────────── minute (0 - 59)
    │ ┌───────────── hour (0 - 23)
    │ │ ┌───────────── day of month (1 - 31)
    │ │ │ ┌───────────── month (1 - 12)
    │ │ │ │ ┌───────────── day of week (0 - 6, 0 = Sunday)
    │ │ │ │ │
    * * * * *
HELP
}

# Output bash completion script
cmd_completion() {
    cat << 'COMPLETION'
# Bash completion for cc-cron
_cc_cron_completion() {
    local cur prev words cword
    _init_completion || return

    _get_job_ids() {
        local meta_file
        for meta_file in ~/.cc-cron/logs/*.meta; do
            [[ -f "$meta_file" ]] || continue
            basename "$meta_file" .meta
        done
    }

    case ${prev} in
        cc-cron)
            COMPREPLY=($(compgen -W "add list remove logs status pause resume show history run edit export import version completion help" -- "${cur}"))
            ;;
        remove|logs|pause|resume|show|history|run)
            COMPREPLY=($(compgen -W "$(_get_job_ids)" -- "${cur}"))
            ;;
        export)
            COMPREPLY=($(compgen -W "$(_get_job_ids)" -- "${cur}"))
            ;;
        edit)
            if [[ ${#words[@]} -eq 3 ]]; then
                COMPREPLY=($(compgen -W "$(_get_job_ids)" -- "${cur}"))
            else
                COMPREPLY=($(compgen -W "--cron --prompt --workdir --model --permission-mode --timeout" -- "${cur}"))
            fi
            ;;
        --model)
            COMPREPLY=($(compgen -W "sonnet opus haiku" -- "${cur}"))
            ;;
        --permission-mode)
            COMPREPLY=($(compgen -W "bypassPermissions acceptEdits auto default" -- "${cur}"))
            ;;
        --workdir)
            _filedir -d
            ;;
        add)
            case ${#words[@]} in
                3)
                    COMPREPLY=($(compgen -W '"0 9 * * 1-5" "0 * * * *" "*/5 * * * *" "0 0 * * *"' -- "${cur}"))
                    ;;
                *)
                    COMPREPLY=($(compgen -W "--once --workdir --model --permission-mode" -- "${cur}"))
                    ;;
            esac
            ;;
        *)
            if [[ " ${words[@]} " =~ " add " ]]; then
                COMPREPLY=($(compgen -W "--once --workdir --model --permission-mode" -- "${cur}"))
            fi
            ;;
    esac
}
complete -F _cc_cron_completion cc-cron
COMPLETION
}

# Main entry point
main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        add)
            ensure_data_dir
            if [[ $# -lt 2 ]]; then
                error "Usage: cc-cron add <cron-expression> <prompt> [options]

Options:
  --once                      Create a one-shot job (auto-removes after success)
  --workdir <path>            Working directory (default: \$CC_WORKDIR or \$HOME)
  --model <name>              Model to use: sonnet, opus, etc. (default: \$CC_MODEL)
  --permission-mode <mode>    Permission mode (default: \$CC_PERMISSION_MODE or bypassPermissions)
  --timeout <seconds>         Timeout for job execution (default: \$CC_TIMEOUT or 0, no timeout)"
            fi
            local cron_expr="$1"
            local prompt="$2"
            shift 2

            # Parse optional flags
            local recurring="true"
            local job_workdir="$CC_WORKDIR"
            local job_model="$CC_MODEL"
            local job_permission="$CC_PERMISSION_MODE"
            local job_timeout="${CC_TIMEOUT:-0}"

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --once)
                        recurring="false"
                        shift
                        ;;
                    --workdir)
                        [[ -z "${2:-}" ]] && error "--workdir requires a path"
                        job_workdir="$2"
                        shift 2
                        ;;
                    --model)
                        [[ -z "${2:-}" ]] && error "--model requires a model name"
                        job_model="$2"
                        shift 2
                        ;;
                    --permission-mode)
                        [[ -z "${2:-}" ]] && error "--permission-mode requires a mode"
                        job_permission="$2"
                        shift 2
                        ;;
                    --timeout)
                        [[ -z "${2:-}" ]] && error "--timeout requires seconds"
                        job_timeout="$2"
                        shift 2
                        ;;
                    *)
                        error "Unknown option: $1"
                        ;;
                esac
            done

            cmd_add "$cron_expr" "$prompt" "$recurring" "$job_workdir" "$job_model" "$job_permission" "$job_timeout"
            ;;
        list)
            cmd_list
            ;;
        remove)
            ensure_data_dir
            if [[ $# -lt 1 ]]; then
                error "Usage: cc-cron remove <job-id>"
            fi
            cmd_remove "$1"
            ;;
        logs)
            ensure_data_dir
            if [[ $# -lt 1 ]]; then
                error "Usage: cc-cron logs <job-id>"
            fi
            cmd_logs "$1"
            ;;
        status)
            ensure_data_dir
            cmd_status
            ;;
        pause)
            ensure_data_dir
            if [[ $# -lt 1 ]]; then
                error "Usage: cc-cron pause <job-id>"
            fi
            cmd_pause "$1"
            ;;
        resume)
            ensure_data_dir
            if [[ $# -lt 1 ]]; then
                error "Usage: cc-cron resume <job-id>"
            fi
            cmd_resume "$1"
            ;;
        show)
            ensure_data_dir
            if [[ $# -lt 1 ]]; then
                error "Usage: cc-cron show <job-id>"
            fi
            cmd_show "$1"
            ;;
        history)
            ensure_data_dir
            if [[ $# -lt 1 ]]; then
                error "Usage: cc-cron history <job-id> [lines]"
            fi
            cmd_history "$1" "${2:-20}"
            ;;
        run)
            ensure_data_dir
            if [[ $# -lt 1 ]]; then
                error "Usage: cc-cron run <job-id>"
            fi
            cmd_run "$1"
            ;;
        edit)
            ensure_data_dir
            if [[ $# -lt 1 ]]; then
                error "Usage: cc-cron edit <job-id> [--cron <expr>] [--prompt <text>] [--workdir <path>] [--model <name>] [--permission-mode <mode>] [--timeout <seconds>]"
            fi
            local edit_job_id="$1"
            shift
            cmd_edit "$edit_job_id" "$@"
            ;;
        export)
            ensure_data_dir
            cmd_export "${1:-}" "${2:-}"
            ;;
        import)
            ensure_data_dir
            if [[ $# -lt 1 ]]; then
                error "Usage: cc-cron import <file>"
            fi
            cmd_import "$1"
            ;;
        version|--version|-v)
            cmd_version
            ;;
        completion)
            cmd_completion
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            error "Unknown command: ${command}. Run 'cc-cron help' for usage."
            ;;
    esac
}

# Only run main if not being sourced for testing
if [[ "${CC_CRON_TEST_MODE:-0}" != "1" ]]; then
    main "$@"
fi
