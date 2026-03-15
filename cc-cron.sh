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
readonly VERSION="1.8.2"

# Configuration
DATA_DIR="${DATA_DIR:-${HOME}/.cc-cron}"
LOG_DIR="${LOG_DIR:-${DATA_DIR}/logs}"
LOCK_DIR="${LOCK_DIR:-${DATA_DIR}/locks}"
CONFIG_FILE="${CONFIG_FILE:-${DATA_DIR}/config}"
CRON_COMMENT_PREFIX="CC-CRON:"

# Crontab cache (performance optimization)
_CRONTAB_CACHE=""

# Store last created job ID (for programmatic use)
LAST_CREATED_JOB_ID=""

# Store file size from remove_file (for tracking)
REMOVE_FILE_SIZE=0

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

# Helper to validate and get numeric value safely
safe_numeric() {
    local value="$1"
    local default="$2"
    [[ "$value" =~ ^[0-9]+$ ]] && echo "$value" || echo "$default"
}

# Environment configuration (can be overridden by config file)
CC_WORKDIR="${CC_WORKDIR:-$HOME}"
CC_PERMISSION_MODE="${CC_PERMISSION_MODE:-bypassPermissions}"
CC_MODEL="${CC_MODEL:-}"
CC_TIMEOUT=$(safe_numeric "${CC_TIMEOUT:-}" "0")

# Ensure data directory exists
ensure_data_dir() {
    mkdir -p "$LOG_DIR" "$LOCK_DIR"
}

# Load configuration from file
load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0

    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue

        # Remove surrounding quotes from value
        value="${value#\"}"
        value="${value%\"}"

        case "$key" in
            workdir|CC_WORKDIR)
                CC_WORKDIR="$value"
                ;;
            model|CC_MODEL)
                CC_MODEL="$value"
                ;;
            permission_mode|CC_PERMISSION_MODE)
                CC_PERMISSION_MODE="$value"
                ;;
            timeout|CC_TIMEOUT)
                CC_TIMEOUT="$value"
                ;;
            data_dir|DATA_DIR)
                # DATA_DIR can only be set before other dirs are created
                warn "DATA_DIR must be set via environment variable, ignoring in config file"
                ;;
        esac
    done < "$CONFIG_FILE"
}

# Get config file path
get_config_file() {
    echo "$CONFIG_FILE"
}

# Helper functions for file paths
get_meta_file() { echo "${LOG_DIR}/${1}.meta"; }
get_log_file() { echo "${LOG_DIR}/${1}.log"; }
get_status_file() { echo "${LOG_DIR}/${1}.status"; }
get_history_file() { echo "${LOG_DIR}/${1}.history"; }
get_run_script() { echo "${DATA_DIR}/run-${1}.sh"; }

# Helper to load job metadata, returns error if not found
load_job_meta() {
    local job_id="$1"
    local meta_file; meta_file=$(get_meta_file "$job_id")
    if [[ ! -f "$meta_file" ]]; then
        error "Job not found: ${job_id}"
    fi
    source "$meta_file"
}

# Extract job ID from a crontab line containing CC-CRON comment
# Usage: extract_job_id <crontab_line>
extract_job_id() {
    local line="$1"
    local temp="${line#*"${CRON_COMMENT_PREFIX}"}"
    echo "${temp%%:*}"
}

# Helper to validate a number is within range
validate_range() {
    local value="$1" min="$2" max="$3" context="$4"
    if [[ "$value" -lt "$min" || "$value" -gt "$max" ]]; then
        error "Invalid value '$value' for $context (must be $min-$max)"
    fi
}

# Helper to remove a file if it exists
# Arguments: file, label, dry_run (optional, default: false)
# Returns: 0 on success, prints removed file info
remove_file() {
    local file="$1"
    local label="$2"
    local dry_run="${3:-false}"

    [[ -f "$file" ]] || return 0

    local file_size
    file_size=$(get_stat "$file" size 2>/dev/null || echo "0")

    if [[ "$dry_run" == "true" ]]; then
        echo "  [dry-run] Would remove ${label}: ${file}"
    else
        rm -f "$file"
        echo "  Removed ${label}: ${file}"
    fi

    # Return file size via global for tracking
    REMOVE_FILE_SIZE="$file_size"
    return 0
}

# Helper to validate job-id argument presence
# Arguments: command_name, args_count_expected, args...
require_job_id() {
    local command="$1"
    shift
    if [[ $# -lt 1 ]]; then
        error "Usage: cc-cron ${command} <job-id>"
    fi
}

# Portable stat helper (supports both Linux and macOS)
# Usage: get_stat <file> <format>
# Formats: size, mtime, mtime_unix
get_stat() {
    local file="$1"
    local format="$2"

    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS stat
        case "$format" in
            size)   stat -f %z "$file" 2>/dev/null ;;
            mtime)  stat -f %Sm "$file" 2>/dev/null ;;
            mtime_unix) stat -f %m "$file" 2>/dev/null ;;
            *) return 1 ;;
        esac
    else
        # Linux stat
        case "$format" in
            size)   stat -c %s "$file" 2>/dev/null ;;
            mtime)  stat -c %y "$file" 2>/dev/null ;;
            mtime_unix) stat -c %Y "$file" 2>/dev/null ;;
            *) return 1 ;;
        esac
    fi
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

# Parse job modification options (--cron, --prompt, --workdir, --model, --permission-mode, --timeout)
# Sets global variables: PARSED_CRON, PARSED_PROMPT, PARSED_WORKDIR, PARSED_MODEL, PARSED_PERMISSION, PARSED_TIMEOUT, PARSED_HAS_CHANGES
parse_job_options() {
    PARSED_CRON=""
    PARSED_PROMPT=""
    PARSED_WORKDIR=""
    PARSED_MODEL=""
    PARSED_PERMISSION=""
    PARSED_TIMEOUT=""
    PARSED_HAS_CHANGES=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cron)
                [[ -z "${2:-}" ]] && error "--cron requires a cron expression"
                validate_cron "$2"
                PARSED_CRON="$2"
                PARSED_HAS_CHANGES=1
                shift 2
                ;;
            --prompt)
                [[ -z "${2:-}" ]] && error "--prompt requires a prompt text"
                PARSED_PROMPT="$2"
                PARSED_HAS_CHANGES=1
                shift 2
                ;;
            --workdir)
                [[ -z "${2:-}" ]] && error "--workdir requires a path"
                validate_workdir "$2"
                PARSED_WORKDIR="$2"
                PARSED_HAS_CHANGES=1
                shift 2
                ;;
            --model)
                PARSED_MODEL="${2:-}"
                PARSED_HAS_CHANGES=1
                shift 2
                ;;
            --permission-mode)
                [[ -z "${2:-}" ]] && error "--permission-mode requires a mode"
                PARSED_PERMISSION="$2"
                PARSED_HAS_CHANGES=1
                shift 2
                ;;
            --timeout)
                [[ -z "${2:-}" ]] && error "--timeout requires seconds"
                PARSED_TIMEOUT="$2"
                PARSED_HAS_CHANGES=1
                shift 2
                ;;
            *)
                error "Unknown option: $1"
                ;;
        esac
    done
}

# Crontab helper functions
# Build a crontab entry for a job
build_cron_entry() {
    local job_id="$1"
    local cron_expr="$2"
    local run_script="$3"
    local recurring="$4"
    local prompt="$5"
    echo "${cron_expr} ${run_script}  # ${CRON_COMMENT_PREFIX}${job_id}:recurring=${recurring}:prompt=${prompt:0:30}"
}

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

# Generate run script for a job (shared by add and edit)
generate_run_script() {
    local job_id="$1"
    local job_workdir="$2"
    local job_model="$3"
    local job_permission="$4"
    local job_timeout="$5"
    local recurring="$6"
    local prompt="$7"

    local log_file; log_file=$(get_log_file "$job_id")
    local status_file; status_file=$(get_status_file "$job_id")
    local lock_file; lock_file=$(get_lock_file "$job_workdir")
    local run_script; run_script=$(get_run_script "$job_id")

    # Build claude options
    local claude_opts="-p"
    [[ -n "$job_model" ]] && claude_opts="$claude_opts --model $job_model"
    [[ "$job_permission" != "default" ]] && claude_opts="$claude_opts --permission-mode $job_permission"

    # Sanitize prompt for safe shell embedding
    local safe_prompt="${prompt//\'/\'\\\'\'}"
    local current_path="$PATH"

    cat > "$run_script" << RUNEOF
#!/usr/bin/env bash
# Auto-generated job runner for ${job_id}
set -e

export PATH="${current_path}"

LOG_FILE="${log_file}"
STATUS_FILE="${status_file}"
HISTORY_FILE="${LOG_DIR}/${job_id}.history"
LOCK_FILE="${lock_file}"
WORKDIR="${job_workdir}"
JOB_ID="${job_id}"
RECURRING="${recurring}"
TIMEOUT="${job_timeout}"
META_FILE="${LOG_DIR}/${job_id}.meta"

cleanup() { exec 9>&-; }
trap cleanup EXIT

exec 9>"\$LOCK_FILE"
if ! flock -n 9; then
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] SKIPPED: Another job is running in \$WORKDIR" >> "\$LOG_FILE"
    exit 0
fi

echo "start_time=\"\$(date '+%Y-%m-%d %H:%M:%S')\"" > "\$STATUS_FILE"
echo "status=\"running\"" >> "\$STATUS_FILE"

cd "\$WORKDIR"
if [[ "\${TIMEOUT:-0}" -gt 0 ]]; then
    timeout "\${TIMEOUT}" claude ${claude_opts} '${safe_prompt}' >> "\$LOG_FILE" 2>&1
else
    claude ${claude_opts} '${safe_prompt}' >> "\$LOG_FILE" 2>&1
fi
EXIT_CODE=\$?

echo "end_time=\"\$(date '+%Y-%m-%d %H:%M:%S')\"" >> "\$STATUS_FILE"
echo "exit_code=\"\${EXIT_CODE}\"" >> "\$STATUS_FILE"

if [[ \$EXIT_CODE -eq 0 ]]; then
    echo "status=\"success\"" >> "\$STATUS_FILE"
    echo "start=\"\${start_time}\" end=\"\$(date '+%Y-%m-%d %H:%M:%S')\" status=\"success\" exit_code=\"0\"" >> "\$HISTORY_FILE"
    if [[ "\$RECURRING" == "false" ]]; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] AUTO-REMOVED: One-shot job completed successfully" >> "\$LOG_FILE"
        (crontab -l 2>/dev/null | grep -v "CC-CRON:\${JOB_ID}:" || true) | crontab -
        rm -f "\$LOG_FILE" "\$STATUS_FILE" "\$META_FILE" "\$HISTORY_FILE" "\$0"
    fi
else
    echo "status=\"failed\"" >> "\$STATUS_FILE"
    echo "start=\"\${start_time}\" end=\"\$(date '+%Y-%m-%d %H:%M:%S')\" status=\"failed\" exit_code=\"\${EXIT_CODE}\"" >> "\$HISTORY_FILE"
    [[ "\$RECURRING" == "false" ]] && echo "[\$(date '+%Y-%m-%d %H:%M:%S')] One-shot job failed - keeping job for retry" >> "\$LOG_FILE"
fi
RUNEOF
    chmod +x "$run_script"
    echo "$run_script"
}

# Write job metadata file
write_meta_file() {
    local job_id="$1"
    local created="$2"
    local cron="$3"
    local recurring="$4"
    local prompt="$5"
    local workdir="$6"
    local model="$7"
    local permission="$8"
    local timeout="$9"
    local run_script="${10:-}"
    local modified="${11:-}"

    local meta_file; meta_file=$(get_meta_file "$job_id")

    {
        echo "id=\"${job_id}\""
        echo "created=\"${created}\""
        [[ -n "$modified" ]] && echo "modified=\"${modified}\""
        echo "cron=\"${cron}\""
        echo "recurring=\"${recurring}\""
        echo "prompt=\"${prompt}\""
        echo "workdir=\"${workdir}\""
        echo "model=\"${model}\""
        echo "permission_mode=\"${permission}\""
        echo "timeout=\"${timeout}\""
        echo "run_script=\"${run_script}\""
    } > "$meta_file"
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
    # Ensure timeout is numeric
    job_timeout=$(safe_numeric "$job_timeout" "0")

    validate_cron "$cron_expr"
    validate_workdir "$job_workdir"

    local job_id
    job_id=$(generate_job_id)
    local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    ensure_data_dir

    # Generate run script using helper
    local run_script
    run_script=$(generate_run_script "$job_id" "$job_workdir" "$job_model" "$job_permission" "$job_timeout" "$recurring" "$prompt")

    # Create the cron entry using helper
    crontab_add_entry "$(build_cron_entry "$job_id" "$cron_expr" "$run_script" "$recurring" "$prompt")"

    # Save job metadata using helper
    write_meta_file "$job_id" "$timestamp" "$cron_expr" "$recurring" "$prompt" "$job_workdir" "$job_model" "$job_permission" "$job_timeout" "$run_script"

    success "Created cron job: ${job_id}"
    info "Schedule: ${cron_expr}"
    info "Recurring: ${recurring}"
    info "Workdir: ${job_workdir}"
    [[ -n "$job_model" ]] && info "Model: ${job_model}"
    info "Permission: ${job_permission}"
    [[ "$job_timeout" -gt 0 ]] && info "Timeout: ${job_timeout}s"
    info "Prompt: ${prompt}"
    info "Log file: $(get_log_file "$job_id")"
    [[ "$recurring" == "false" ]] && info "One-shot job: will auto-remove after successful execution"

    # Store job ID for programmatic use (e.g., import)
    LAST_CREATED_JOB_ID="$job_id"
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
            # Extract job ID from comment using helper
            local job_id; job_id=$(extract_job_id "$line")

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
    local follow="${2:-false}"
    local log_file; log_file=$(get_log_file "$job_id")

    if [[ ! -f "$log_file" ]]; then
        error "No logs found for job: ${job_id}"
    fi

    if [[ "$follow" == "true" ]]; then
        info "Following logs for job ${job_id} (Ctrl+C to stop)..."
        echo "================================="
        tail -f "$log_file"
    else
        info "Logs for job ${job_id}:"
        echo "================================="
        cat "$log_file"
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

    if [[ ! -f "$paused_file" ]]; then
        error "Job ${job_id} is not paused"
    fi

    # Load metadata (errors if not found)
    load_job_meta "$job_id"

    # Recreate cron entry using helper
    local run_script; run_script=$(get_run_script "$job_id")
    crontab_add_entry "$(build_cron_entry "$job_id" "$cron" "$run_script" "$recurring" "$prompt")"
    rm -f "$paused_file"

    success "Resumed job: ${job_id}"
    info "Schedule: ${cron}"
}

# Show detailed information for a specific job
cmd_show() {
    local job_id="$1"

    # Load metadata (errors if not found)
    load_job_meta "$job_id"

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
            # Parse using bash parameter expansion (more portable than grep -oP)
            local h_start h_end h_status h_exit
            h_start="${line#*start=\"}" && h_start="${h_start%%\"*}"
            h_end="${line#*end=\"}" && h_end="${h_end%%\"*}"
            h_status="${line#*status=\"}" && h_status="${h_status%%\"*}"
            h_exit="${line#*exit_code=\"}" && h_exit="${h_exit%%\"*}"

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

    # Load metadata (errors if not found)
    load_job_meta "$job_id"

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

    # Load current metadata (errors if not found)
    load_job_meta "$job_id"

    # Parse options using helper
    parse_job_options "$@"

    # Apply parsed options (fall back to current values)
    local new_cron="${PARSED_CRON:-$cron}"
    local new_prompt="${PARSED_PROMPT:-$prompt}"
    local new_workdir="${PARSED_WORKDIR:-$workdir}"
    local new_model="${PARSED_MODEL:-${model:-}}"
    local new_permission="${PARSED_PERMISSION:-$permission_mode}"
    local new_timeout="${PARSED_TIMEOUT:-${timeout:-0}}"
    local has_changes="$PARSED_HAS_CHANGES"

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

    # Update metadata file using helper
    local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local new_run_script; new_run_script=$(get_run_script "$job_id")
    write_meta_file "$job_id" "$created" "$new_cron" "$recurring" "$new_prompt" "$new_workdir" "$new_model" "$new_permission" "$new_timeout" "$new_run_script" "$timestamp"

    # Generate new run script using helper
    generate_run_script "$job_id" "$new_workdir" "$new_model" "$new_permission" "$new_timeout" "$recurring" "$new_prompt" > /dev/null

    # Re-add to crontab if not paused
    if [[ "$was_paused" -eq 0 ]]; then
        crontab_add_entry "$(build_cron_entry "$job_id" "$new_cron" "$new_run_script" "$recurring" "$new_prompt")"
    fi

    success "Updated job: ${job_id}"
    [[ "$cron" != "$new_cron" ]] && info "Schedule: ${cron} → ${new_cron}"
    [[ "$prompt" != "$new_prompt" ]] && info "Prompt updated"
    [[ "$workdir" != "$new_workdir" ]] && info "Workdir: ${workdir} → ${new_workdir}"
}

# Clone an existing job with a new ID
cmd_clone() {
    local source_id="$1"
    shift || true

    # Load source job metadata
    load_job_meta "$source_id"

    # Parse options using helper
    parse_job_options "$@"

    # Apply parsed options (fall back to source values)
    local new_cron="${PARSED_CRON:-$cron}"
    local new_prompt="${PARSED_PROMPT:-$prompt}"
    local new_workdir="${PARSED_WORKDIR:-$workdir}"
    local new_model="${PARSED_MODEL:-${model:-}}"
    local new_permission="${PARSED_PERMISSION:-$permission_mode}"
    local new_timeout="${PARSED_TIMEOUT:-${timeout:-0}}"

    # Create new job with copied settings
    cmd_add "$new_cron" "$new_prompt" "$recurring" "$new_workdir" "$new_model" "$new_permission" "$new_timeout"

    success "Cloned job ${source_id} → ${LAST_CREATED_JOB_ID}"
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
            last_run=$(get_stat "$log_file" mtime | cut -d. -f1)
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
        # Export specific job - validate existence
        if [[ ! -f "$(get_meta_file "$job_id")" ]]; then
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

        # Pause if needed (use job ID from LAST_CREATED_JOB_ID)
        if [[ "$job_paused" == "true" && -n "${LAST_CREATED_JOB_ID:-}" ]]; then
            cmd_pause "$LAST_CREATED_JOB_ID"
        fi

        ((imported++)) || true
    done

    success "Imported ${imported} job(s), skipped ${skipped}"
}

# Helper to purge old files by extension (used by cmd_purge)
# Arguments: directory, extension, days, dry_run, file_label
# Returns: number of files purged (via global PURGE_COUNT)
PURGE_COUNT=0
PURGE_BYTES=0
purge_old_files() {
    local dir="$1"
    local ext="$2"
    local days="$3"
    local dry_run="$4"
    local label="$5"

    PURGE_COUNT=0
    PURGE_BYTES=0

    # shellcheck disable=SC2231
    for file in "${dir}"/*.${ext}; do
        [[ -f "$file" ]] || continue

        # Check if file is old enough
        local file_age
        file_age=$(find "$file" -mtime +"$days" 2>/dev/null)
        [[ -n "$file_age" ]] || continue

        local file_size
        file_size=$(get_stat "$file" size || echo "0")

        if [[ "$dry_run" == "true" ]]; then
            echo "  [dry-run] Would remove ${label}: ${file}"
        else
            rm -f "$file"
            echo "  Removed ${label}: ${file}"
        fi
        ((PURGE_COUNT++)) || true
        ((PURGE_BYTES += file_size)) || true
    done
}

# Purge old logs and orphaned files
cmd_purge() {
    local days="${1:-7}"
    local dry_run="${2:-false}"

    # Validate days argument
    [[ "$days" =~ ^[0-9]+$ ]] || error "Invalid days argument: ${days}"

    info "Purging files older than ${days} days..."
    [[ "$dry_run" == "true" ]] && info "(dry-run mode - no files will be deleted)"
    echo

    local purged_orphans=0

    # Get list of active job IDs from crontab
    local -A active_jobs
    while IFS= read -r line; do
        if [[ "$line" == *"${CRON_COMMENT_PREFIX}"* ]]; then
            local job_id; job_id=$(extract_job_id "$line")
            active_jobs["$job_id"]=1
        fi
    done < <(get_crontab)

    # Also check paused jobs
    for paused_file in "${DATA_DIR}"/*.paused; do
        [[ -f "$paused_file" ]] || continue
        local job_id
        job_id=$(basename "$paused_file" .paused)
        active_jobs["$job_id"]=1
    done

    # Clean up log files
    purge_old_files "$LOG_DIR" "log" "$days" "$dry_run" "log"
    local purged_logs=$PURGE_COUNT
    local freed_bytes=$PURGE_BYTES

    # Clean up history files
    purge_old_files "$LOG_DIR" "history" "$days" "$dry_run" "history"
    local purged_history=$PURGE_COUNT
    ((freed_bytes += PURGE_BYTES)) || true

    # Clean up orphaned files (files for jobs not in crontab)
    for meta_file in "${LOG_DIR}"/*.meta; do
        [[ -f "$meta_file" ]] || continue
        local job_id
        job_id=$(basename "$meta_file" .meta)

        # Skip if job is active
        [[ -z "${active_jobs[$job_id]:-}" ]] || continue

        # Remove all files for this orphaned job using helper
        remove_file "$meta_file" "orphan" "$dry_run"
        ((purged_orphans++)) || true; ((freed_bytes += REMOVE_FILE_SIZE)) || true

        remove_file "$(get_log_file "$job_id")" "orphan" "$dry_run"
        ((purged_orphans++)) || true; ((freed_bytes += REMOVE_FILE_SIZE)) || true

        remove_file "$(get_status_file "$job_id")" "orphan" "$dry_run"
        ((purged_orphans++)) || true; ((freed_bytes += REMOVE_FILE_SIZE)) || true

        remove_file "$(get_history_file "$job_id")" "orphan" "$dry_run"
        ((purged_orphans++)) || true; ((freed_bytes += REMOVE_FILE_SIZE)) || true

        remove_file "$(get_run_script "$job_id")" "orphan" "$dry_run"
        ((purged_orphans++)) || true; ((freed_bytes += REMOVE_FILE_SIZE)) || true
    done

    # Clean up old run scripts for removed jobs
    for run_script in "${DATA_DIR}"/run-*.sh; do
        [[ -f "$run_script" ]] || continue
        local job_id
        job_id=$(basename "$run_script" .sh)
        job_id="${job_id#run-}"

        # Skip if job is active
        [[ -z "${active_jobs[$job_id]:-}" ]] || continue

        remove_file "$run_script" "orphan script" "$dry_run"
        ((purged_orphans++)) || true; ((freed_bytes += REMOVE_FILE_SIZE)) || true
    done

    # Summary
    local freed_mb
    freed_mb=$(echo "scale=2; ${freed_bytes} / 1048576" | bc)
    echo
    if [[ "$dry_run" == "true" ]]; then
        info "Dry-run summary:"
    else
        success "Purge complete:"
    fi
    echo "  Logs purged:     ${purged_logs}"
    echo "  History purged:  ${purged_history}"
    echo "  Orphans removed: ${purged_orphans}"
    echo "  Space freed:     ${freed_mb} MB"
}

# Manage configuration
cmd_config() {
    local action="${1:-list}"

    case "$action" in
        list)
            info "Current configuration:"
            echo
            echo "  Config file: ${CONFIG_FILE}"
            echo "  Data dir:    ${DATA_DIR}"
            echo
            echo "  Default workdir:    ${CC_WORKDIR}"
            echo "  Default model:      ${CC_MODEL:-<not set>}"
            echo "  Default permission: ${CC_PERMISSION_MODE}"
            echo "  Default timeout:    ${CC_TIMEOUT}s"
            echo
            if [[ -f "$CONFIG_FILE" ]]; then
                echo "Config file contents:"
                echo "----------------------"
                cat "$CONFIG_FILE"
            else
                echo "No config file exists. Create one with:"
                echo "  cc-cron config set workdir /path/to/dir"
                echo "  cc-cron config set model sonnet"
            fi
            ;;
        set)
            local key="${2:-}"
            local value="${3:-}"

            [[ -z "$key" ]] && error "Usage: cc-cron config set <key> <value>"
            [[ -z "$value" ]] && error "Usage: cc-cron config set <key> <value>"

            # Validate key
            case "$key" in
                workdir|model|permission_mode|timeout)
                    # Valid keys
                    ;;
                *)
                    error "Invalid config key: ${key}. Valid keys: workdir, model, permission_mode, timeout"
                    ;;
            esac

            # Validate value
            case "$key" in
                workdir)
                    [[ -d "$value" ]] || error "Directory not found: ${value}"
                    ;;
                model)
                    # Accept any model name
                    ;;
                permission_mode)
                    case "$value" in
                        bypassPermissions|acceptEdits|auto|default)
                            ;;
                        *)
                            error "Invalid permission mode: ${value}. Valid: bypassPermissions, acceptEdits, auto, default"
                            ;;
                    esac
                    ;;
                timeout)
                    [[ "$value" =~ ^[0-9]+$ ]] || error "Timeout must be a number"
                    ;;
            esac

            # Update config file
            ensure_data_dir

            # Read existing config or create new
            local -A config_map
            if [[ -f "$CONFIG_FILE" ]]; then
                while IFS='=' read -r k v; do
                    [[ "$k" =~ ^[[:space:]]*# ]] && continue
                    [[ -z "$k" ]] && continue
                    v="${v#\"}"
                    v="${v%\"}"
                    config_map["$k"]="$v"
                done < "$CONFIG_FILE"
            fi

            # Set new value
            config_map["$key"]="$value"

            # Write config file
            {
                echo "# cc-cron configuration file"
                echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
                echo
                for k in "${!config_map[@]}"; do
                    echo "${k}=\"${config_map[$k]}\""
                done
            } > "$CONFIG_FILE"

            success "Set ${key}=\"${value}\""
            info "Config saved to: ${CONFIG_FILE}"
            ;;
        unset)
            local key="${2:-}"

            [[ -z "$key" ]] && error "Usage: cc-cron config unset <key>"

            if [[ ! -f "$CONFIG_FILE" ]]; then
                warn "No config file exists"
                return 0
            fi

            # Remove key from config
            local temp_file
            temp_file=$(mktemp)
            grep -v "^${key}=" "$CONFIG_FILE" > "$temp_file" || true
            mv "$temp_file" "$CONFIG_FILE"

            success "Unset ${key}"
            ;;
        *)
            error "Unknown config action: ${action}. Use: list, set, unset"
            ;;
    esac
}

# Diagnose common issues
cmd_doctor() {
    local issues=0
    local warnings=0

    echo "CC-Cron Health Check"
    echo "===================="
    echo

    # Check 1: Data directory
    echo "1. Checking data directory..."
    if [[ -d "$DATA_DIR" ]]; then
        echo "   ✓ Data directory exists: ${DATA_DIR}"
    else
        echo "   ✗ Data directory not found: ${DATA_DIR}"
        echo "     Fix: Run 'cc-cron add' to create it automatically"
        ((issues++)) || true
    fi

    # Check 2: Crontab access
    echo
    echo "2. Checking crontab access..."
    if crontab -l &>/dev/null; then
        echo "   ✓ Crontab is accessible"
    else
        echo "   ! No crontab configured (this is OK if no jobs are scheduled)"
        ((warnings++)) || true
    fi

    # Check 3: Claude CLI
    echo
    echo "3. Checking Claude CLI..."
    if command -v claude &>/dev/null; then
        echo "   ✓ Claude CLI found: $(command -v claude)"
        # Check version if possible
        if claude --version &>/dev/null; then
            echo "     Version: $(claude --version 2>&1 | head -1)"
        fi
    else
        echo "   ✗ Claude CLI not found in PATH"
        echo "     Fix: Install Claude CLI from https://claude.ai/code"
        ((issues++)) || true
    fi

    # Check 4: Required tools
    echo
    echo "4. Checking required tools..."
    local missing_tools=()
    for tool in flock md5sum; do
        if command -v "$tool" &>/dev/null; then
            echo "   ✓ ${tool} available"
        else
            echo "   ✗ ${tool} not found"
            missing_tools+=("$tool")
            ((issues++)) || true
        fi
    done
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        echo "     Fix: Install missing tools with your package manager"
    fi

    # Check 5: Optional tools
    echo
    echo "5. Checking optional tools..."
    if command -v jq &>/dev/null; then
        echo "   ✓ jq available (for import/export)"
    else
        echo "   ! jq not found (needed for import command)"
        echo "     Install: apt-get install jq or brew install jq"
        ((warnings++)) || true
    fi

    # Check 6: Lock files
    echo
    echo "6. Checking lock files..."
    local lock_count
    lock_count=$(find "$LOCK_DIR" -name "*.lock" 2>/dev/null | wc -l)
    echo "   Active lock files: ${lock_count}"
    if [[ "$lock_count" -gt 0 ]]; then
        echo "   ! Some jobs may be stuck or running"
        for lock_file in "$LOCK_DIR"/*.lock; do
            [[ -f "$lock_file" ]] || continue
            local lock_age
            lock_age=$(get_stat "$lock_file" mtime_unix)
            local current_time
            current_time=$(date +%s)
            local age_minutes=$(( (current_time - lock_age) / 60 ))
            if [[ $age_minutes -gt 60 ]]; then
                echo "     ! Old lock: ${lock_file} (${age_minutes} minutes old)"
                ((warnings++)) || true
            fi
        done
    fi

    # Check 7: Job consistency
    echo
    echo "7. Checking job consistency..."
    local crontab_jobs=0
    local meta_files=0
    local orphaned=0

    # Count jobs in crontab
    while IFS= read -r line; do
        if [[ "$line" == *"${CRON_COMMENT_PREFIX}"* ]]; then
            ((crontab_jobs++)) || true
            local job_id; job_id=$(extract_job_id "$line")
            local meta_file
            meta_file=$(get_meta_file "$job_id")
            if [[ ! -f "$meta_file" ]]; then
                echo "   ! Missing metadata for job: ${job_id}"
                ((orphaned++)) || true
            fi
        fi
    done < <(get_crontab)

    # Count meta files
    for meta_file in "${LOG_DIR}"/*.meta; do
        [[ -f "$meta_file" ]] || continue
        ((meta_files++)) || true
    done

    echo "   Jobs in crontab: ${crontab_jobs}"
    echo "   Metadata files:  ${meta_files}"

    if [[ $orphaned -gt 0 ]]; then
        echo "   ! ${orphaned} orphaned crontab entries found"
        echo "     Fix: Run 'cc-cron purge' or manually clean crontab"
        ((issues++)) || true
    fi

    # Check 8: Disk space
    echo
    echo "8. Checking disk space..."
    local data_size
    data_size=$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo "0")
    echo "   Data directory size: ${data_size}"

    local available_space
    available_space=$(df -h "$DATA_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
    echo "   Available space: ${available_space}"

    # Check 9: Permission issues
    echo
    echo "9. Checking permissions..."
    local perm_issues=0
    for dir in "$DATA_DIR" "$LOG_DIR" "$LOCK_DIR"; do
        if [[ -d "$dir" ]]; then
            if [[ ! -w "$dir" ]]; then
                echo "   ✗ No write permission: ${dir}"
                ((perm_issues++)) || true
            fi
        fi
    done
    if [[ $perm_issues -eq 0 ]]; then
        echo "   ✓ All directories are writable"
    else
        ((issues++)) || true
    fi

    # Summary
    echo
    echo "================================"
    if [[ $issues -eq 0 && $warnings -eq 0 ]]; then
        echo -e "${GREEN}All checks passed!${NC}"
    else
        if [[ $issues -gt 0 ]]; then
            echo -e "${RED}Found ${issues} issue(s) that need attention${NC}"
        fi
        if [[ $warnings -gt 0 ]]; then
            echo -e "${YELLOW}Found ${warnings} warning(s)${NC}"
        fi
    fi
    echo

    # Return non-zero if there are issues
    [[ $issues -eq 0 ]]
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
    logs <job-id> [--tail]          Show logs for a job (--tail for live follow)
    pause <job-id>                  Pause a scheduled job
    resume <job-id>                 Resume a paused job
    enable <job-id>                 Alias for resume
    disable <job-id>                Alias for pause
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
    clone <job-id> [options]        Clone an existing job with a new ID
        --cron <expr>               Override cron schedule
        --prompt <text>             Override prompt
        --workdir <path>            Override working directory
        --model <name>              Override model
        --permission-mode <mode>    Override permission mode
        --timeout <seconds>         Override timeout
    export [job-id] [file]          Export job(s) to JSON (to file or stdout)
    import <file>                   Import jobs from JSON file
    purge [days]                    Purge old logs and orphaned files (default: 7 days)
        --dry-run                   Show what would be deleted without actually deleting
    config [action] [key] [value]  Manage configuration
        list                        Show current configuration
        set <key> <value>           Set a configuration value
        unset <key>                 Remove a configuration value
        Valid keys: workdir, model, permission_mode, timeout
    doctor                          Diagnose common issues
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
            COMPREPLY=($(compgen -W "add list remove logs status pause resume enable disable show history run edit clone export import purge config doctor version completion help" -- "${cur}"))
            ;;
        remove|pause|resume|enable|disable|show|history|run|clone)
            COMPREPLY=($(compgen -W "$(_get_job_ids)" -- "${cur}"))
            ;;
        logs)
            if [[ ${#words[@]} -eq 3 ]]; then
                COMPREPLY=($(compgen -W "$(_get_job_ids)" -- "${cur}"))
            elif [[ ${#words[@]} -eq 4 ]]; then
                COMPREPLY=($(compgen -W "--tail -f" -- "${cur}"))
            fi
            ;;
        export)
            COMPREPLY=($(compgen -W "$(_get_job_ids)" -- "${cur}"))
            ;;
        config)
            if [[ ${#words[@]} -eq 3 ]]; then
                COMPREPLY=($(compgen -W "list set unset" -- "${cur}"))
            elif [[ ${#words[@]} -eq 4 ]]; then
                COMPREPLY=($(compgen -W "workdir model permission_mode timeout" -- "${cur}"))
            fi
            ;;
        edit|clone)
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
            local job_timeout
            job_timeout=$(safe_numeric "${CC_TIMEOUT:-0}" "0")

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
            require_job_id "$command" "$@"
            cmd_remove "$1"
            ;;
        logs)
            ensure_data_dir
            require_job_id "$command" "$@"
            local logs_job_id="$1"
            shift
            local follow="false"
            if [[ "${1:-}" == "--tail" || "${1:-}" == "-f" ]]; then
                follow="true"
            fi
            cmd_logs "$logs_job_id" "$follow"
            ;;
        status)
            ensure_data_dir
            cmd_status
            ;;
        pause|disable)
            ensure_data_dir
            require_job_id "$command" "$@"
            cmd_pause "$1"
            ;;
        resume|enable)
            ensure_data_dir
            require_job_id "$command" "$@"
            cmd_resume "$1"
            ;;
        show)
            ensure_data_dir
            require_job_id "$command" "$@"
            cmd_show "$1"
            ;;
        history)
            ensure_data_dir
            require_job_id "$command" "$@"
            cmd_history "$1" "${2:-20}"
            ;;
        run)
            ensure_data_dir
            require_job_id "$command" "$@"
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
        clone)
            ensure_data_dir
            require_job_id "$command" "$@"
            local clone_source_id="$1"
            shift
            cmd_clone "$clone_source_id" "$@"
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
        purge)
            ensure_data_dir
            local purge_days="7"
            local dry_run="false"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --dry-run)
                        dry_run="true"
                        shift
                        ;;
                    *)
                        purge_days="$1"
                        shift
                        ;;
                esac
            done
            cmd_purge "$purge_days" "$dry_run"
            ;;
        config)
            ensure_data_dir
            load_config
            cmd_config "${1:-list}" "${2:-}" "${3:-}"
            ;;
        doctor)
            ensure_data_dir
            cmd_doctor
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
