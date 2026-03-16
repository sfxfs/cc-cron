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
readonly VERSION="2.4.76"

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
        error "Job not found: ${job_id}" "$EXIT_NOT_FOUND"
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
        error "Invalid value '$value' for $context (must be $min-$max)" "$EXIT_INVALID_ARGS"
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

    local file_size; file_size=$(get_stat "$file" size 2>/dev/null || echo "0")

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

# Helper to remove a file and track purge stats (increments PURGE_COUNT, PURGE_BYTES)
# Arguments: file, label, dry_run (optional, default: false)
purge_single_file() {
    remove_file "$1" "$2" "${3:-false}"
    ((PURGE_COUNT++)) || true
    ((PURGE_BYTES += REMOVE_FILE_SIZE)) || true
}

# Helper to validate job-id argument presence
# Arguments: command_name, args_count_expected, args...
require_job_id() {
    local command="$1"
    shift
    [[ $# -lt 1 ]] && error "Usage: cc-cron ${command} <job-id>" "$EXIT_INVALID_ARGS"
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

# Escape string for safe embedding in shell variable assignment
# Escapes backslashes and double quotes
escape_shell_string() {
    local s="${1//\\/\\\\}"  # Escape backslashes first
    s="${s//\"/\\\"}"        # Then escape double quotes
    echo "$s"
}

# Escape string for JSON output
# Escapes backslashes, double quotes, and control characters
escape_json_string() {
    local s="${1//\\/\\\\}"  # Escape backslashes first
    s="${s//\"/\\\"}"        # Then escape double quotes
    s="${s//$'\n'/\\n}"      # Escape newlines
    s="${s//$'\r'/\\r}"      # Escape carriage returns
    s="${s//$'\t'/\\t}"      # Escape tabs
    echo "$s"
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
    error "Failed to generate unique job ID after 10 attempts" "$EXIT_ERROR"
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
            [[ "$step" =~ ^[0-9]+$ ]] || error "Invalid step value in '$value' for $field_name" "$EXIT_INVALID_ARGS"
            [[ "$step" -ge 1 && "$step" -le "$max" ]] && return 0
            error "Invalid step value '$step' in '$value' for $field_name (must be 1-$max)" "$EXIT_INVALID_ARGS"
            ;;
    esac

    # Handle range n-m
    case "$value" in
        *-*)
            local start="${value%%-*}"
            local end="${value#*-}"
            [[ "$start" =~ ^[0-9]+$ ]] || error "Invalid range '$value' for $field_name" "$EXIT_INVALID_ARGS"
            [[ "$end" =~ ^[0-9]+$ ]] || error "Invalid range '$value' for $field_name" "$EXIT_INVALID_ARGS"
            validate_range "$start" "$min" "$max" "$field_name range start"
            validate_range "$end" "$min" "$max" "$field_name range end"
            [[ "$start" -gt "$end" ]] && \
                error "Invalid range '$value' for $field_name (start > end)" "$EXIT_INVALID_ARGS"
            return 0
            ;;
    esac

    # Handle simple number
    [[ "$value" =~ ^[0-9]+$ ]] || error "Invalid cron field value '$value' for $field_name" "$EXIT_INVALID_ARGS"
    validate_range "$value" "$min" "$max" "$field_name"
}

# Validate cron expression (full validation, optimized)
validate_cron() {
    local cron="$1"

    # Split into fields using read (faster than array slicing)
    local -a fields; read -ra fields <<< "$cron"

    # Early exit for wrong field count
    if [[ ${#fields[@]} -ne 5 ]]; then
        error "Invalid cron expression: $cron (expected 5 fields: minute hour day month weekday)" "$EXIT_INVALID_ARGS"
    fi

    # Validate each field: minute (0-59), hour (0-23), day (1-31), month (1-12), weekday (0-6)
    validate_cron_field "${fields[0]}" 0 59 "minute"
    validate_cron_field "${fields[1]}" 0 23 "hour"
    validate_cron_field "${fields[2]}" 1 31 "day of month"
    validate_cron_field "${fields[3]}" 1 12 "month"
    validate_cron_field "${fields[4]}" 0 6 "day of week"
}

# Check if cron expression is valid (returns true/false, no exit)
is_valid_cron() {
    local cron="$1"

    # Run validation in subshell to catch errors without exiting
    ( validate_cron "$cron" ) 2>/dev/null
}

# Validate working directory exists
validate_workdir() {
    [[ -d "$1" ]] || error "Directory not found: $1" "$EXIT_INVALID_ARGS"
}

# Validate permission mode
validate_permission_mode() {
    case "$1" in
        bypassPermissions|acceptEdits|auto|default)
            return 0
            ;;
        *)
            error "Invalid permission mode: $1. Valid: bypassPermissions, acceptEdits, auto, default" "$EXIT_INVALID_ARGS"
            ;;
    esac
}

# Validate timeout value
validate_timeout() {
    [[ "$1" =~ ^[0-9]+$ ]] || error "Timeout must be a non-negative number" "$EXIT_INVALID_ARGS"
}

# Parse job modification options (--cron, --prompt, --workdir, --model, --permission-mode, --timeout, --tags)
# Sets global variables: PARSED_CRON, PARSED_PROMPT, PARSED_WORKDIR, PARSED_MODEL, PARSED_PERMISSION, PARSED_TIMEOUT, PARSED_TAGS, PARSED_HAS_CHANGES
parse_job_options() {
    PARSED_CRON=""
    PARSED_PROMPT=""
    PARSED_WORKDIR=""
    PARSED_MODEL=""
    PARSED_MODEL_SET=0
    PARSED_PERMISSION=""
    PARSED_TIMEOUT=""
    PARSED_TAGS=""
    PARSED_TAGS_SET=0
    PARSED_HAS_CHANGES=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cron)
                [[ -z "${2:-}" ]] && error "--cron requires a cron expression" "$EXIT_INVALID_ARGS"
                validate_cron "$2"
                PARSED_CRON="$2"
                PARSED_HAS_CHANGES=1
                shift 2
                ;;
            --prompt)
                [[ -z "${2:-}" ]] && error "--prompt requires a prompt text" "$EXIT_INVALID_ARGS"
                PARSED_PROMPT="$2"
                PARSED_HAS_CHANGES=1
                shift 2
                ;;
            --workdir)
                [[ -z "${2:-}" ]] && error "--workdir requires a path" "$EXIT_INVALID_ARGS"
                validate_workdir "$2"
                PARSED_WORKDIR="$2"
                PARSED_HAS_CHANGES=1
                shift 2
                ;;
            --model)
                PARSED_MODEL="${2:-}"
                PARSED_MODEL_SET=1
                PARSED_HAS_CHANGES=1
                shift 2
                ;;
            --permission-mode)
                [[ -z "${2:-}" ]] && error "--permission-mode requires a mode" "$EXIT_INVALID_ARGS"
                validate_permission_mode "$2"
                PARSED_PERMISSION="$2"
                PARSED_HAS_CHANGES=1
                shift 2
                ;;
            --timeout)
                [[ -z "${2:-}" ]] && error "--timeout requires seconds" "$EXIT_INVALID_ARGS"
                validate_timeout "$2"
                PARSED_TIMEOUT="$2"
                PARSED_HAS_CHANGES=1
                shift 2
                ;;
            --tags)
                PARSED_TAGS="${2:-}"
                PARSED_TAGS_SET=1
                PARSED_HAS_CHANGES=1
                shift 2
                ;;
            *)
                error "Unknown option: $1" "$EXIT_INVALID_ARGS"
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
    get_crontab | { grep -v "$pattern" || true; } | crontab -
    invalidate_crontab_cache
}

# Generate lock file path from directory path
get_lock_file() {
    local dir="$1"
    local dir_hash; dir_hash=$(echo -n "$dir" | md5sum | cut -d' ' -f1)
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

# Source profile files to load environment variables (API keys, etc.)
[[ -f ~/.bash_profile ]] && source ~/.bash_profile
[[ -f ~/.bashrc ]] && source ~/.bashrc

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
    local tags="${12:-}"

    local meta_file; meta_file=$(get_meta_file "$job_id")

    # Escape string values for proper shell sourcing
    local safe_prompt; safe_prompt=$(escape_shell_string "$prompt")
    local safe_workdir; safe_workdir=$(escape_shell_string "$workdir")
    local safe_model; safe_model=$(escape_shell_string "$model")
    local safe_permission; safe_permission=$(escape_shell_string "$permission")
    local safe_run_script; safe_run_script=$(escape_shell_string "$run_script")

    {
        echo "id=\"${job_id}\""
        echo "created=\"${created}\""
        [[ -n "$modified" ]] && echo "modified=\"$(escape_shell_string "$modified")\""
        echo "cron=\"${cron}\""
        echo "recurring=\"${recurring}\""
        echo "prompt=\"${safe_prompt}\""
        echo "workdir=\"${safe_workdir}\""
        echo "model=\"${safe_model}\""
        echo "permission_mode=\"${safe_permission}\""
        echo "timeout=\"${timeout}\""
        [[ -n "$tags" ]] && echo "tags=\"$(escape_shell_string "$tags")\""
        echo "run_script=\"${safe_run_script}\""
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
    local quiet="${8:-false}"
    local job_tags="${9:-}"

    validate_cron "$cron_expr"
    validate_workdir "$job_workdir"
    validate_permission_mode "$job_permission"
    validate_timeout "$job_timeout"
    # Ensure timeout is numeric
    job_timeout=$(safe_numeric "$job_timeout" "0")

    local job_id; job_id=$(generate_job_id)
    local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    ensure_data_dir

    # Generate run script using helper
    local run_script; run_script=$(generate_run_script "$job_id" "$job_workdir" "$job_model" \
        "$job_permission" "$job_timeout" "$recurring" "$prompt")

    # Create the cron entry using helper
    crontab_add_entry "$(build_cron_entry "$job_id" "$cron_expr" "$run_script" "$recurring" "$prompt")"

    # Save job metadata using helper
    write_meta_file "$job_id" "$timestamp" "$cron_expr" "$recurring" "$prompt" \
        "$job_workdir" "$job_model" "$job_permission" "$job_timeout" "$run_script" "" "$job_tags"

    # Store job ID for programmatic use (e.g., import)
    LAST_CREATED_JOB_ID="$job_id"

    # Output based on quiet mode
    if [[ "$quiet" == "true" ]]; then
        echo "$job_id"
    else
        success "Created cron job: ${job_id}"
        info "Schedule: ${cron_expr}"
        info "Recurring: ${recurring}"
        info "Workdir: ${job_workdir}"
        [[ -n "$job_model" ]] && info "Model: ${job_model}" || true
        info "Permission: ${job_permission}"
        [[ "$job_timeout" -gt 0 ]] && info "Timeout: ${job_timeout}s" || true
        [[ -n "$job_tags" ]] && info "Tags: ${job_tags}" || true
        info "Prompt: ${prompt}"
        info "Log file: $(get_log_file "$job_id")"
        [[ "$recurring" == "false" ]] && info "One-shot job: will auto-remove after successful execution" || true
    fi
}

# List all cc-cron jobs (optimized: single crontab read)
cmd_list() {
    local filter_tag="${1:-}"
    local json_output="${2:-false}"
    local found=0
    local -a jobs=()

    if [[ "$json_output" != "true" ]]; then
        echo "Scheduled Claude Code Cron Jobs:"
        echo "================================="
        echo
    fi

    # Single crontab read with caching
    local crontab_content; crontab_content=$(get_crontab) || return 0

    while IFS= read -r line; do
        if [[ "$line" == *"${CRON_COMMENT_PREFIX}"* ]]; then
            # Extract job ID from comment using helper
            local job_id; job_id=$(extract_job_id "$line")

            # Read metadata if exists
            local meta_file; meta_file=$(get_meta_file "$job_id")
            if [[ -f "$meta_file" ]]; then
                # Reset optional fields to avoid persistence from previous iterations
                local tags="" model="" modified=""
                source "$meta_file"

                # Filter by tag if specified
                if [[ -n "$filter_tag" ]]; then
                    [[ -n "${tags:-}" && ",${tags}," == *",${filter_tag},"* ]] || continue
                fi

                found=1

                if [[ "$json_output" == "true" ]]; then
                    # Build JSON object for this job
                    local escaped_prompt; escaped_prompt=$(escape_json_string "$prompt")
                    local escaped_workdir; escaped_workdir=$(escape_json_string "${workdir:-$CC_WORKDIR}")
                    local escaped_permission; escaped_permission=$(escape_json_string "${permission_mode:-$CC_PERMISSION_MODE}")
                    local job_json="{"
                    job_json+="\"id\":\"${id}\""
                    job_json+=",\"created\":\"${created}\""
                    job_json+=",\"cron\":\"${cron}\""
                    job_json+=",\"recurring\":${recurring}"
                    job_json+=",\"workdir\":\"${escaped_workdir}\""
                    job_json+=",\"permission\":\"${escaped_permission}\""
                    job_json+=",\"prompt\":\"${escaped_prompt}\""
                    [[ -n "${model:-}" ]] && job_json+=",\"model\":\"$(escape_json_string "$model")\""
                    [[ -n "${tags:-}" ]] && job_json+=",\"tags\":\"$(escape_json_string "$tags")\""
                    job_json+="}"
                    jobs+=("$job_json")
                else
                    echo "Job ID: ${id}"
                    echo "  Created: ${created}"
                    echo "  Schedule: ${cron}"
                    echo "  Recurring: ${recurring}"
                    echo "  Workdir: ${workdir:-$CC_WORKDIR}"
                    [[ -n "${model:-}" ]] && echo "  Model: ${model}"
                    echo "  Permission: ${permission_mode:-$CC_PERMISSION_MODE}"
                    [[ -n "${tags:-}" ]] && echo "  Tags: ${tags}"
                    echo "  Prompt: ${prompt}"
                    echo
                fi
            else
                # Skip jobs without metadata when filtering
                [[ -n "$filter_tag" ]] && continue
                found=1
                if [[ "$json_output" == "true" ]]; then
                    jobs+=("{\"id\":\"${job_id}\",\"error\":\"metadata missing\"}")
                else
                    echo "Job ID: ${job_id} (metadata missing)"
                    echo "  Raw: ${line}"
                    echo
                fi
            fi
        fi
    done <<< "$crontab_content"

    if [[ "$json_output" == "true" ]]; then
        echo "["
        local first=1
        for job in "${jobs[@]}"; do
            if [[ $first -eq 1 ]]; then
                echo "  ${job}"
                first=0
            else
                echo "  ,${job}"
            fi
        done
        echo "]"
    elif [[ "$found" -eq 0 ]]; then
        [[ -n "$filter_tag" ]] && info "No jobs found with tag: ${filter_tag}" || info "No scheduled jobs found."
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
        error "Job not found: ${job_id}" "$EXIT_NOT_FOUND"
    fi
}

# Show logs for a job
cmd_logs() {
    local job_id="$1"
    local follow="${2:-false}"
    local log_file; log_file=$(get_log_file "$job_id")

    if [[ ! -f "$log_file" ]]; then
        # Check if job exists to give better error message
        if [[ -f "$(get_meta_file "$job_id")" ]]; then
            error "No logs found for job: ${job_id}. The job may not have run yet." "$EXIT_NOT_FOUND"
        else
            error "Job not found: ${job_id}" "$EXIT_NOT_FOUND"
        fi
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
    local paused_file="${DATA_DIR}/${job_id}.paused"
    local meta_file; meta_file=$(get_meta_file "$job_id")

    # Check if job exists (either in crontab or paused)
    if [[ ! -f "$meta_file" ]]; then
        error "Job not found: ${job_id}" "$EXIT_NOT_FOUND"
    fi

    # Check if already paused
    [[ -f "$paused_file" ]] && { warn "Job ${job_id} is already paused"; return 0; }

    # Check if job is in crontab (it should be if not paused)
    if ! crontab_has_entry "${CRON_COMMENT_PREFIX}${job_id}"; then
        error "Job ${job_id} has no crontab entry (may be orphaned)" "$EXIT_ERROR"
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
        if [[ ! -f "$(get_meta_file "$job_id")" ]]; then
            error "Job not found: ${job_id}" "$EXIT_NOT_FOUND"
        fi
        error "Job ${job_id} is not paused" "$EXIT_INVALID_ARGS"
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

# Calculate next run time from cron expression
# Supports: hourly (0 * * * *), daily (0 H * * *), weekly (0 H * * D)
calculate_next_run() {
    local cron="$1"
    local now; now=$(date +%s)

    # Parse cron fields
    local -a fields; read -ra fields <<< "$cron"
    local minute="${fields[0]}" hour="${fields[1]}" day="${fields[2]}" month="${fields[3]}" weekday="${fields[4]}"
    local next_time="" schedule_desc=""

    # Handle common patterns
    if [[ "$minute" == "*" && "$hour" == "*" ]]; then
        # Every minute
        next_time=$((now + 60))
        schedule_desc="every minute"
    elif [[ "$hour" == "*" && "$minute" != "*" ]]; then
        # Check for step pattern like */5
        if [[ "$minute" == */* ]]; then
            local step="${minute#*/}"
            if [[ "$step" =~ ^[0-9]+$ ]]; then
                # Every N minutes
                local current_minute; current_minute=$(date +%M)
                current_minute=$((10#$current_minute))
                local minutes_until=$(( (step - current_minute % step) % step ))
                if [[ $minutes_until -eq 0 ]]; then
                    minutes_until=$step
                fi
                next_time=$((now + minutes_until * 60))
                schedule_desc="every ${step} minutes"
            else
                # Invalid step pattern
                schedule_desc="custom schedule (${cron})"
                next_time=0
            fi
        else
            # Every hour at specific minute
            local current_minute; current_minute=$(date +%M)
            current_minute=$((10#$current_minute))
            local target_minute=$((10#$minute))

            local minutes_until=$(( (target_minute - current_minute + 60) % 60 ))
            if [[ $minutes_until -eq 0 ]]; then
                minutes_until=60
            fi
            next_time=$((now + minutes_until * 60))
            schedule_desc="hourly at minute $minute"
        fi
    elif [[ "$day" == "*" && "$month" == "*" && "$weekday" == "*" ]]; then
        # Check for hour step pattern like */2
        if [[ "$hour" == */* ]]; then
            local hour_step="${hour#*/}"
            if [[ "$hour_step" =~ ^[0-9]+$ ]]; then
                # Every N hours at specific minute
                local current_hour current_minute
                current_hour=$(date +%H)
                current_minute=$(date +%M)
                current_hour=$((10#$current_hour))
                current_minute=$((10#$current_minute))
                local target_minute=$((10#$minute))

                local hours_until=$(( (hour_step - current_hour % hour_step) % hour_step ))
                if [[ $hours_until -eq 0 ]]; then
                    # Check if we've passed the minute this hour
                    if [[ $current_minute -ge $target_minute ]]; then
                        hours_until=$hour_step
                    fi
                fi
                next_time=$((now + hours_until * 3600 + (target_minute - current_minute) * 60))
                schedule_desc="every ${hour_step} hours at minute ${minute}"
            else
                # Invalid step pattern
                schedule_desc="custom schedule (${cron})"
                next_time=0
            fi
        else
            # Daily at specific time
            local current_hour current_minute
            current_hour=$(date +%H)
            current_minute=$(date +%M)
            current_hour=$((10#$current_hour))
            current_minute=$((10#$current_minute))

            local target_hour=$((10#$hour))
            local target_minute=$((10#$minute))

            local minutes_today=$((target_hour * 60 + target_minute))
            local minutes_now=$((current_hour * 60 + current_minute))

            local minutes_until=$((minutes_today - minutes_now))
            if [[ $minutes_until -le 0 ]]; then
                minutes_until=$((minutes_until + 1440))  # Add 24 hours
            fi
            next_time=$((now + minutes_until * 60))
            schedule_desc="daily at ${hour}:${minute}"
        fi
    elif [[ "$day" == "*" && "$month" == "*" && "$weekday" != "*" ]]; then
        # Check if weekday is a simple single value (not a range or list)
        if [[ "$weekday" =~ ^[0-6]$ ]]; then
            # Weekly on a specific day
            local current_weekday; current_weekday=$(date +%u)  # 1-7, Monday is 1
            current_weekday=$((current_weekday % 7))  # Convert to 0-6, Sunday is 0

            local target_weekday=$((10#$weekday))

            local current_hour; current_hour=$(date +%H)
            local current_minute; current_minute=$(date +%M)
            current_hour=$((10#$current_hour))
            current_minute=$((10#$current_minute))

            local target_hour=$((10#$hour))
            local target_minute=$((10#$minute))

            local days_until=$(( (target_weekday - current_weekday + 7) % 7 ))
            if [[ $days_until -eq 0 ]]; then
                # Same day, check if time has passed
                local minutes_target=$((target_hour * 60 + target_minute))
                local minutes_now=$((current_hour * 60 + current_minute))
                if [[ $minutes_target -le $minutes_now ]]; then
                    days_until=7
                fi
            fi

            local minutes_until=$((days_until * 1440 + target_hour * 60 + target_minute
                - current_hour * 60 - current_minute))
            next_time=$((now + minutes_until * 60))

            local day_names=("Sunday" "Monday" "Tuesday" "Wednesday" "Thursday" "Friday" "Saturday")
            schedule_desc="weekly on ${day_names[$target_weekday]} at ${hour}:${minute}"
        else
            # Complex weekday pattern (range, list, etc.)
            schedule_desc="custom schedule (${cron})"
            next_time=0
        fi
    else
        # Complex schedule - show cron expression
        schedule_desc="custom schedule (${cron})"
        next_time=0
    fi

    if [[ $next_time -gt 0 ]]; then
        date -d "@${next_time}" "+%Y-%m-%d %H:%M" 2>/dev/null || date -r "$next_time" "+%Y-%m-%d %H:%M" 2>/dev/null
    fi
}

# Show next scheduled run times
cmd_next() {
    local job_id="${1:-}"
    local count="${2:-5}"

    echo "Upcoming Scheduled Runs:"
    echo "========================="
    echo

    local crontab_content; crontab_content=$(get_crontab) || { info "No crontab configured"; return 0; }

    local found=0

    while IFS= read -r line; do
        if [[ "$line" == *"${CRON_COMMENT_PREFIX}"* ]]; then
            local id; id=$(extract_job_id "$line")

            # Filter by job_id if specified
            if [[ -n "$job_id" && "$id" != "$job_id" ]]; then
                continue
            fi

            local meta_file; meta_file=$(get_meta_file "$id")
            if [[ ! -f "$meta_file" ]]; then
                continue
            fi

            # Reset optional fields to avoid persistence from previous iterations
            local tags="" model="" modified=""
            source "$meta_file"

            # Check if paused
            local paused_file="${DATA_DIR}/${id}.paused"
            local paused_status=""
            [[ -f "$paused_file" ]] && paused_status=" (PAUSED)"

            local next_run; next_run=$(calculate_next_run "$cron")

            echo -e "  ${GREEN}${id}${NC}${paused_status}"
            echo "    Schedule: ${cron}"
            [[ -n "$next_run" ]] && echo "    Next run: ${next_run}"
            echo "    Prompt:   ${prompt:0:50}${prompt:50:+...}"
            echo

            found=$((found + 1))
        fi
    done <<< "$crontab_content"

    if [[ $found -eq 0 ]]; then
        [[ -n "$job_id" ]] && info "Job not found: ${job_id}" || info "No scheduled jobs found."
    fi
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
    [[ -n "${tags:-}" ]] && echo "  Tags:         ${tags}"
    echo
    echo "  Prompt:"
    echo "    ${prompt}"
    echo

    # Check if paused
    local paused_file="${DATA_DIR}/${job_id}.paused"
    [[ -f "$paused_file" ]] && { echo -e "  Status:       ${YELLOW}PAUSED${NC}"; echo; }

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
    [[ -f "$log_file" ]] && echo "  Log file: ${log_file}"
}

# Show execution history for a job
cmd_history() {
    local job_id="$1"
    local lines="${2:-20}"
    local history_file; history_file=$(get_history_file "$job_id")
    local log_file; log_file=$(get_log_file "$job_id")

    if [[ ! -f "$log_file" ]]; then
        # Check if job exists to give better error message
        if [[ -f "$(get_meta_file "$job_id")" ]]; then
            error "No logs found for job: ${job_id}. The job may not have run yet." "$EXIT_NOT_FOUND"
        else
            error "Job not found: ${job_id}" "$EXIT_NOT_FOUND"
        fi
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
        error "Run script not found for job: ${job_id}" "$EXIT_NOT_FOUND"
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
    local new_model; new_model="$([[ "$PARSED_MODEL_SET" -eq 1 ]] && echo "$PARSED_MODEL" || echo "${model:-}")"
    local new_permission="${PARSED_PERMISSION:-$permission_mode}"
    local new_timeout="${PARSED_TIMEOUT:-${timeout:-0}}"
    local new_tags; new_tags="$([[ "$PARSED_TAGS_SET" -eq 1 ]] && echo "$PARSED_TAGS" || echo "${tags:-}")"
    local has_changes="$PARSED_HAS_CHANGES"

    if [[ "$has_changes" -eq 0 ]]; then
        warn "No changes specified. Use --cron, --prompt, --workdir, --model, --permission-mode, --timeout, or --tags"
        return 0
    fi

    # Remove old crontab entry if not paused
    [[ ! -f "${DATA_DIR}/${job_id}.paused" ]] && crontab_remove_entry "${CRON_COMMENT_PREFIX}${job_id}"

    # Update metadata file using helper
    local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local new_run_script; new_run_script=$(get_run_script "$job_id")
    write_meta_file "$job_id" "$created" "$new_cron" "$recurring" "$new_prompt" \
        "$new_workdir" "$new_model" "$new_permission" "$new_timeout" "$new_run_script" "$timestamp" "$new_tags"

    # Generate new run script using helper
    generate_run_script "$job_id" "$new_workdir" "$new_model" "$new_permission" \
        "$new_timeout" "$recurring" "$new_prompt" > /dev/null

    # Re-add to crontab if not paused
    [[ ! -f "${DATA_DIR}/${job_id}.paused" ]] && crontab_add_entry "$(build_cron_entry "$job_id" "$new_cron" "$new_run_script" "$recurring" "$new_prompt")"

    success "Updated job: ${job_id}"
    [[ "$cron" != "$new_cron" ]] && info "Schedule: ${cron} → ${new_cron}" || true
    [[ "$prompt" != "$new_prompt" ]] && info "Prompt updated" || true
    [[ "$workdir" != "$new_workdir" ]] && info "Workdir: ${workdir} → ${new_workdir}" || true
    [[ "${tags:-}" != "$new_tags" ]] && info "Tags: ${tags:-none} → ${new_tags:-none}" || true
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
    local new_model; new_model="$([[ "$PARSED_MODEL_SET" -eq 1 ]] && echo "$PARSED_MODEL" || echo "${model:-}")"
    local new_permission="${PARSED_PERMISSION:-$permission_mode}"
    local new_timeout="${PARSED_TIMEOUT:-${timeout:-0}}"
    local new_tags; new_tags="$([[ "$PARSED_TAGS_SET" -eq 1 ]] && echo "$PARSED_TAGS" || echo "${tags:-}")"

    # Create new job with copied settings
    cmd_add "$new_cron" "$new_prompt" "$recurring" "$new_workdir" \
        "$new_model" "$new_permission" "$new_timeout" "false" "$new_tags"

    success "Cloned job ${source_id} → ${LAST_CREATED_JOB_ID}"
}

# Show status of all jobs and recent executions
cmd_status() {
    info "CC-Cron Status Report"
    echo "======================"
    echo

    # Count jobs from crontab
    local crontab_content; crontab_content=$(get_crontab) || { warn "No crontab configured for current user"; return; }

    local job_count; job_count=$(echo "$crontab_content" | { grep "${CRON_COMMENT_PREFIX}" || true; } | wc -l)
    echo "Total scheduled jobs: ${job_count}"
    echo

    # Show recent executions with status (single pass)
    echo "Recent executions:"
    echo "------------------"

    local success_count=0 failed_count=0 running_count=0 unknown_count=0

    for meta_file in "${LOG_DIR}"/*.meta; do
        [[ -f "$meta_file" ]] || continue
        # Reset optional fields to avoid persistence from previous iterations
        local tags="" model="" modified=""
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
            local last_run; last_run=$(get_stat "$log_file" mtime | cut -d. -f1)
            echo -e "  ${id}: ${YELLOW}? NO STATUS${NC} (last activity: ${last_run})"
            echo "    Workdir: ${workdir}"
            echo
            ((unknown_count++)) || true
        fi
    done

    echo -e "Summary: ${GREEN}${success_count} succeeded${NC}, ${RED}${failed_count} failed${NC}, "
    echo -e "  ${YELLOW}${running_count} running${NC}, ${unknown_count} unknown${NC}"
}

# Show execution statistics for jobs
cmd_stats() {
    local job_id="${1:-}"

    if [[ -n "$job_id" ]]; then
        # Show stats for specific job
        _show_job_stats "$job_id"
    else
        # Show stats for all jobs
        local found=0
        for meta_file in "${LOG_DIR}"/*.meta; do
            [[ -f "$meta_file" ]] || continue
            local id; id=$(basename "$meta_file" .meta)
            _show_job_stats "$id"
            found=$((found + 1))
        done

        if [[ $found -eq 0 ]]; then
            info "No jobs found."
        fi
    fi
}

# Helper function to show stats for a single job
_show_job_stats() {
    local job_id="$1"
    local history_file; history_file=$(get_history_file "$job_id")
    local meta_file; meta_file=$(get_meta_file "$job_id")

    if [[ ! -f "$meta_file" ]]; then
        error "Job not found: ${job_id}" "$EXIT_NOT_FOUND"
    fi

    # Reset optional fields to avoid persistence from previous iterations
    local tags="" model="" modified=""
    source "$meta_file"

    echo -e "Job: ${GREEN}${job_id}${NC}"
    echo "Schedule: ${cron}"

    # Count executions from history file
    local total_runs=0 success_count=0 failed_count=0
    local last_success="" last_failure=""
    local total_duration=0 duration_count=0

    if [[ -f "$history_file" ]]; then
        while IFS= read -r line; do
            ((total_runs++)) || true

            # Parse status
            local h_status; h_status="${line#*status=\"}" && h_status="${h_status%%\"*}"

            # Parse times for duration calculation
            local h_start h_end
            h_start="${line#*start=\"}" && h_start="${h_start%%\"*}"
            h_end="${line#*end=\"}" && h_end="${h_end%%\"*}"

            case "$h_status" in
                success)
                    ((success_count++)) || true
                    last_success="$h_end"
                    ;;
                failed)
                    ((failed_count++)) || true
                    last_failure="$h_end"
                    ;;
            esac

            # Calculate duration if we have both start and end
            if [[ -n "$h_start" && -n "$h_end" ]]; then
                local start_ts end_ts duration
                # Handle both Linux (date -d) and macOS (date -j -f)
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    start_ts=$(date -j -f "%Y-%m-%d %H:%M:%S" "$h_start" +%s 2>/dev/null) || continue
                    end_ts=$(date -j -f "%Y-%m-%d %H:%M:%S" "$h_end" +%s 2>/dev/null) || continue
                else
                    start_ts=$(date -d "$h_start" +%s 2>/dev/null) || continue
                    end_ts=$(date -d "$h_end" +%s 2>/dev/null) || continue
                fi
                duration=$((end_ts - start_ts))
                total_duration=$((total_duration + duration))
                ((duration_count++)) || true
            fi
        done < "$history_file"
    fi

    echo "Total runs: ${total_runs}"
    echo -e "  ${GREEN}Success: ${success_count}${NC}"
    echo -e "  ${RED}Failed:  ${failed_count}${NC}"

    # Calculate success rate
    if [[ $total_runs -gt 0 ]]; then
        local success_rate; success_rate=$((success_count * 100 / total_runs))
        echo "  Success rate: ${success_rate}%"
    fi

    # Calculate average duration
    if [[ $duration_count -gt 0 ]]; then
        local avg_duration; avg_duration=$((total_duration / duration_count))
        local avg_min=$((avg_duration / 60))
        local avg_sec=$((avg_duration % 60))
        echo "  Avg duration: ${avg_min}m ${avg_sec}s"
    fi

    # Show last execution times
    [[ -n "$last_success" ]] && echo "  Last success: ${last_success}"
    [[ -n "$last_failure" ]] && echo "  Last failure: ${last_failure}"

    echo
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
            error "Job not found: ${job_id}" "$EXIT_NOT_FOUND"
        fi
        jobs+=("$job_id")
    else
        # Export all jobs
        for meta_file in "${LOG_DIR}"/*.meta; do
            [[ -f "$meta_file" ]] || continue
            local id; id=$(basename "$meta_file" .meta)
            jobs+=("$id")
        done
    fi

    if [[ ${#jobs[@]} -eq 0 ]]; then
        warn "No jobs to export"
        return 0
    fi

    # Build JSON output
    local json_output timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    json_output='{"version":"1.0","exported_at":"'"${timestamp}"'","jobs":['
    local first=1

    for job_id in "${jobs[@]}"; do
        local meta_file; meta_file=$(get_meta_file "$job_id")
        [[ -f "$meta_file" ]] || continue
        # Reset optional fields to avoid persistence from previous iterations
        local tags="" model="" modified=""
        source "$meta_file"

        # Check if paused
        local paused_file="${DATA_DIR}/${job_id}.paused"
        local is_paused; is_paused="$([[ -f "$paused_file" ]] && echo true || echo false)"

        if [[ "$first" -eq 1 ]]; then
            first=0
        else
            json_output+=","
        fi

        # Escape values for JSON output
        local escaped_prompt; escaped_prompt=$(escape_json_string "$prompt")
        local escaped_workdir; escaped_workdir=$(escape_json_string "$workdir")
        local escaped_model; escaped_model=$(escape_json_string "${model:-}")
        local escaped_permission; escaped_permission=$(escape_json_string "$permission_mode")
        local escaped_tags; escaped_tags=$(escape_json_string "${tags:-}")

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
        json_output+='"tags":"'"${escaped_tags}"'",'
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
        error "File not found: ${input_file}" "$EXIT_NOT_FOUND"
    fi

    # Check for jq
    if ! command -v jq &>/dev/null; then
        error "jq is required for import. Install with: apt-get install jq or brew install jq" "$EXIT_ERROR"
    fi

    # Validate JSON syntax
    if ! jq '.' "$input_file" >/dev/null 2>&1; then
        error "Invalid JSON in file: ${input_file}" "$EXIT_INVALID_ARGS"
    fi

    # Parse JSON
    local job_count; job_count=$(jq '.jobs | length' "$input_file")

    if [[ "$job_count" -eq 0 ]]; then
        warn "No jobs found in import file"
        return 0
    fi

    info "Found ${job_count} job(s) to import"

    local imported=0 skipped=0 i

    for ((i = 0; i < job_count; i++)); do
        local job_json; job_json=$(jq -c ".jobs[$i]" "$input_file")

        local job_cron job_prompt job_recurring job_workdir job_model job_permission job_timeout job_paused job_tags
        job_cron=$(jq -r '.cron' <<< "$job_json")
        job_prompt=$(jq -r '.prompt' <<< "$job_json")
        job_recurring=$(jq -r '.recurring' <<< "$job_json")
        job_workdir=$(jq -r '.workdir' <<< "$job_json")
        job_model=$(jq -r '.model' <<< "$job_json")
        job_permission=$(jq -r '.permission_mode' <<< "$job_json")
        job_timeout=$(jq -r '.timeout' <<< "$job_json")
        job_paused=$(jq -r '.paused' <<< "$job_json")
        job_tags=$(jq -r '.tags // ""' <<< "$job_json")

        # Validate cron expression
        if ! is_valid_cron "$job_cron"; then
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
        cmd_add "$job_cron" "$job_prompt" "$job_recurring" "$job_workdir" \
            "$job_model" "$job_permission" "$job_timeout" "false" "$job_tags"

        # Pause if needed (use job ID from LAST_CREATED_JOB_ID)
        [[ "$job_paused" == "true" && -n "${LAST_CREATED_JOB_ID:-}" ]] && cmd_pause "$LAST_CREATED_JOB_ID"

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
        local file_age; file_age=$(find "$file" -mtime +"$days" 2>/dev/null)
        [[ -n "$file_age" ]] || continue

        local file_size; file_size=$(get_stat "$file" size || echo "0")

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
    [[ "$days" =~ ^[0-9]+$ ]] || error "Invalid days argument: ${days}" "$EXIT_INVALID_ARGS"

    info "Purging files older than ${days} days..."
    [[ "$dry_run" == "true" ]] && info "(dry-run mode - no files will be deleted)"
    echo

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
        local job_id; job_id=$(basename "$paused_file" .paused)
        active_jobs["$job_id"]=1
    done

    # Clean up log files
    purge_old_files "$LOG_DIR" "log" "$days" "$dry_run" "log"
    local purged_logs=$PURGE_COUNT freed_bytes=$PURGE_BYTES

    # Clean up history files
    purge_old_files "$LOG_DIR" "history" "$days" "$dry_run" "history"
    local purged_history=$PURGE_COUNT
    ((freed_bytes += PURGE_BYTES)) || true

    # Clean up orphaned files (files for jobs not in crontab)
    # Reset counters for orphan tracking
    PURGE_COUNT=0
    PURGE_BYTES=0
    for meta_file in "${LOG_DIR}"/*.meta; do
        [[ -f "$meta_file" ]] || continue
        local job_id; job_id=$(basename "$meta_file" .meta)

        # Skip if job is active
        [[ -z "${active_jobs[$job_id]:-}" ]] || continue

        # Remove all files for this orphaned job
        purge_single_file "$meta_file" "orphan" "$dry_run"
        purge_single_file "$(get_log_file "$job_id")" "orphan" "$dry_run"
        purge_single_file "$(get_status_file "$job_id")" "orphan" "$dry_run"
        purge_single_file "$(get_history_file "$job_id")" "orphan" "$dry_run"
        purge_single_file "$(get_run_script "$job_id")" "orphan" "$dry_run"
    done

    # Clean up old run scripts for removed jobs
    for run_script in "${DATA_DIR}"/run-*.sh; do
        [[ -f "$run_script" ]] || continue
        local job_id; job_id=$(basename "$run_script" .sh)
        job_id="${job_id#run-}"

        # Skip if job is active
        [[ -z "${active_jobs[$job_id]:-}" ]] || continue

        purge_single_file "$run_script" "orphan script" "$dry_run"
    done

    local purged_orphans=$PURGE_COUNT
    ((freed_bytes += PURGE_BYTES)) || true

    # Summary
    local freed_mb_int freed_mb
    freed_mb_int=$((freed_bytes * 100 / 1048576))
    if [[ $freed_mb_int -lt 100 ]]; then
        freed_mb="0.${freed_mb_int}"
    else
        freed_mb="${freed_mb_int:0:-2}.${freed_mb_int: -2}"
    fi
    echo
    [[ "$dry_run" == "true" ]] && info "Dry-run summary:" || success "Purge complete:"
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

            [[ -z "$key" ]] && error "Usage: cc-cron config set <key> <value>" "$EXIT_INVALID_ARGS"
            [[ -z "$value" ]] && error "Usage: cc-cron config set <key> <value>" "$EXIT_INVALID_ARGS"

            # Validate key and value
            case "$key" in
                workdir)
                    [[ -d "$value" ]] || error "Directory not found: ${value}" "$EXIT_INVALID_ARGS"
                    ;;
                model)
                    # Accept any model name
                    ;;
                permission_mode)
                    validate_permission_mode "$value"
                    ;;
                timeout)
                    validate_timeout "$value"
                    ;;
                *)
                    error "Invalid config key: ${key}. Valid keys: workdir, model, permission_mode, timeout" "$EXIT_INVALID_ARGS"
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

            [[ -z "$key" ]] && error "Usage: cc-cron config unset <key>" "$EXIT_INVALID_ARGS"

            if [[ ! -f "$CONFIG_FILE" ]]; then
                warn "No config file exists"
                return 0
            fi

            # Remove key from config
            local temp_file; temp_file=$(mktemp)
            grep -v "^${key}=" "$CONFIG_FILE" > "$temp_file" || true
            mv "$temp_file" "$CONFIG_FILE"

            success "Unset ${key}"
            ;;
        *)
            error "Unknown config action: ${action}. Use: list, set, unset" "$EXIT_INVALID_ARGS"
            ;;
    esac
}

# Diagnose common issues
cmd_doctor() {
    local issues=0 warnings=0

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
        claude --version &>/dev/null && echo "     Version: $(claude --version 2>&1 | head -1)"
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
    [[ ${#missing_tools[@]} -gt 0 ]] && echo "     Fix: Install missing tools with your package manager"

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
    local lock_count; lock_count=$(find "$LOCK_DIR" -name "*.lock" 2>/dev/null | wc -l)
    echo "   Active lock files: ${lock_count}"
    if [[ "$lock_count" -gt 0 ]]; then
        echo "   ! Some jobs may be stuck or running"
        for lock_file in "$LOCK_DIR"/*.lock; do
            [[ -f "$lock_file" ]] || continue
            local lock_age; lock_age=$(get_stat "$lock_file" mtime_unix)
            local current_time; current_time=$(date +%s)
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
    local crontab_jobs=0 meta_files=0 orphaned=0

    # Count jobs in crontab
    while IFS= read -r line; do
        if [[ "$line" == *"${CRON_COMMENT_PREFIX}"* ]]; then
            ((crontab_jobs++)) || true
            local job_id; job_id=$(extract_job_id "$line")
            local meta_file; meta_file=$(get_meta_file "$job_id")
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
    local data_size; data_size=$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo "0")
    echo "   Data directory size: ${data_size}"

    local available_space; available_space=$(df -h "$DATA_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
    echo "   Available space: ${available_space}"

    # Check 9: Permission issues
    echo
    echo "9. Checking permissions..."
    local perm_issues=0
    for dir in "$DATA_DIR" "$LOG_DIR" "$LOCK_DIR"; do
        if [[ -d "$dir" && ! -w "$dir" ]]; then
            echo "   ✗ No write permission: ${dir}"
            ((perm_issues++)) || true
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
        [[ $issues -gt 0 ]] && echo -e "${RED}Found ${issues} issue(s) that need attention${NC}"
        [[ $warnings -gt 0 ]] && echo -e "${YELLOW}Found ${warnings} warning(s)${NC}"
    fi
    echo

    # Return non-zero if there are issues
    [[ $issues -eq 0 ]]
}

# Show version
cmd_version() {
    echo "cc-cron version ${VERSION}"
}

# Show help for a specific command
help_add() {
    cat << 'HELP'
cc-cron add - Add a scheduled job

USAGE:
    cc-cron add <cron-expression> <prompt> [options]

ARGUMENTS:
    <cron-expression>  Standard 5-field cron expression
                       minute (0-59) hour (0-23) day-of-month (1-31) month (1-12) day-of-week (0-6)
    <prompt>           The prompt to send to Claude Code

OPTIONS:
    --once                      Create a one-shot job (auto-removes after success)
    --workdir <path>            Working directory for this job (default: $HOME)
    --model <name>              Model to use: sonnet, opus, haiku, etc.
    --permission-mode <mode>    Permission mode: bypassPermissions, acceptEdits, auto, default
    --timeout <seconds>         Timeout for job execution (0 = no timeout, default)
    --tags <tags>               Comma-separated tags for organization (e.g., 'prod,backup')
    --quiet, -q                 Only output the job ID (useful for scripting)

EXAMPLES:
    cc-cron add "0 9 * * 1-5" "Run daily tests"
    cc-cron add "0 * * * *" "Check status" --model sonnet
    cc-cron add "30 14 28 2 *" "Reminder" --once
    cc-cron add "0 0 * * *" "Daily task" --tags prod,backup
    cc-cron add "0 0 * * *" "Daily task" --quiet
HELP
}

help_edit() {
    cat << 'HELP'
cc-cron edit - Edit a job's settings

USAGE:
    cc-cron edit <job-id> [options]

OPTIONS:
    --cron <expr>               Update cron schedule
    --prompt <text>             Update prompt
    --workdir <path>            Update working directory
    --model <name>              Update model (use "" to clear)
    --permission-mode <mode>    Update permission mode
    --timeout <seconds>         Update timeout
    --tags <tags>               Update tags (use "" to clear)

EXAMPLES:
    cc-cron edit myjob --cron "0 12 * * *"
    cc-cron edit myjob --prompt "New prompt" --model opus
    cc-cron edit myjob --tags "prod,backup"
    cc-cron edit myjob --model ""  # Clear model setting
HELP
}

help_clone() {
    cat << 'HELP'
cc-cron clone - Clone an existing job

USAGE:
    cc-cron clone <job-id> [options]

OPTIONS:
    --cron <expr>               Override cron schedule
    --prompt <text>             Override prompt
    --workdir <path>            Override working directory
    --model <name>              Override model (use "" to clear)
    --permission-mode <mode>    Override permission mode
    --timeout <seconds>         Override timeout
    --tags <tags>               Override tags (use "" to clear)

EXAMPLES:
    cc-cron clone myjob
    cc-cron clone myjob --cron "0 0 * * *"
    cc-cron clone myjob --model haiku --tags "dev"
HELP
}

help_config() {
    cat << 'HELP'
cc-cron config - Manage default configuration

USAGE:
    cc-cron config list              Show current configuration
    cc-cron config set <key> <value> Set a configuration value
    cc-cron config unset <key>       Remove a configuration value

VALID KEYS:
    workdir          Default working directory
    model            Default model (sonnet, opus, haiku)
    permission_mode  Default permission mode
    timeout          Default timeout in seconds

EXAMPLES:
    cc-cron config set workdir /home/user/project
    cc-cron config set model sonnet
    cc-cron config unset model
HELP
}

help_purge() {
    cat << 'HELP'
cc-cron purge - Clean up old data

USAGE:
    cc-cron purge [days] [--dry-run]

ARGUMENTS:
    days      Purge files older than this many days (default: 7)

OPTIONS:
    --dry-run   Show what would be deleted without actually deleting

DESCRIPTION:
    Removes:
    - Log files older than specified days
    - History files older than specified days
    - Orphaned files (files for jobs no longer in crontab)

EXAMPLES:
    cc-cron purge
    cc-cron purge 30
    cc-cron purge --dry-run
HELP
}

help_logs() {
    cat << 'HELP'
cc-cron logs - View job logs

USAGE:
    cc-cron logs <job-id> [--tail]

ARGUMENTS:
    <job-id>   The job ID to view logs for

OPTIONS:
    --tail, -f   Follow log output in real-time

EXAMPLES:
    cc-cron logs abc123
    cc-cron logs abc123 --tail
HELP
}

help_run() {
    cat << 'HELP'
cc-cron run - Execute a job immediately

USAGE:
    cc-cron run <job-id>

ARGUMENTS:
    <job-id>   The job ID to run

DESCRIPTION:
    Executes the job synchronously and displays output.
    Useful for testing job configuration.

EXAMPLES:
    cc-cron run abc123
HELP
}

help_show() {
    cat << 'HELP'
cc-cron show - Display job details

USAGE:
    cc-cron show <job-id>

ARGUMENTS:
    <job-id>   The job ID to display

DESCRIPTION:
    Shows complete job information including:
    - Metadata (ID, created, schedule, recurring)
    - Configuration (workdir, model, permission, timeout)
    - Full prompt text
    - Last execution status (if available)
    - Execution statistics (total runs, success/failure count)
HELP
}

help_history() {
    cat << 'HELP'
cc-cron history - View execution history

USAGE:
    cc-cron history <job-id> [lines]

ARGUMENTS:
    <job-id>   The job ID to view history for
    lines      Number of entries to show (default: 20)

DESCRIPTION:
    Displays execution history with timestamps and status.

EXAMPLES:
    cc-cron history abc123
    cc-cron history abc123 50
HELP
}

help_stats() {
    cat << 'HELP'
cc-cron stats - Show execution statistics

USAGE:
    cc-cron stats [job-id]

ARGUMENTS:
    [job-id]   Optional job ID to show specific job stats

DESCRIPTION:
    Displays execution statistics including:
    - Total runs
    - Success/failure counts
    - Success rate
    - Average duration
    - Last success/failure times

EXAMPLES:
    cc-cron stats           # Show stats for all jobs
    cc-cron stats abc123    # Show stats for specific job
HELP
}

help_next() {
    cat << 'HELP'
cc-cron next - Show upcoming scheduled runs

USAGE:
    cc-cron next [job-id]

ARGUMENTS:
    [job-id]   Optional job ID to show specific job

DESCRIPTION:
    Displays the next scheduled run time for all jobs
    or a specific job. Supports common cron patterns:
    - Hourly:  "N * * * *" (at minute N)
    - Daily:   "N H * * *" (at hour H, minute N)
    - Weekly:  "N H * * D" (on weekday D at H:N)

EXAMPLES:
    cc-cron next              # Show all upcoming runs
    cc-cron next abc123       # Show next run for specific job
HELP
}

help_list() {
    cat << 'HELP'
cc-cron list - List scheduled jobs

USAGE:
    cc-cron list [tag] [options]

ARGUMENTS:
    tag      Filter jobs by tag (optional)

OPTIONS:
    --json   Output in JSON format (machine-readable)

DESCRIPTION:
    Lists all scheduled jobs with their details.
    Can filter to show only jobs with a specific tag.

EXAMPLES:
    cc-cron list              # List all jobs
    cc-cron list prod         # List only jobs tagged 'prod'
    cc-cron list backup       # List only jobs tagged 'backup'
    cc-cron list --json       # List all jobs in JSON format
    cc-cron list prod --json  # List 'prod' jobs in JSON format
HELP
}

help_status() {
    cat << 'HELP'
cc-cron status - Show status overview

USAGE:
    cc-cron status

DESCRIPTION:
    Shows an overview of all scheduled jobs including:
    - Total job count
    - Recent execution status
    - Running/success/failed counts

EXAMPLES:
    cc-cron status
HELP
}

help_pause() {
    cat << 'HELP'
cc-cron pause - Pause a scheduled job

USAGE:
    cc-cron pause <job-id>

ARGUMENTS:
    job-id      Job ID to pause

DESCRIPTION:
    Temporarily disable a scheduled job without removing it.
    The job will not run until resumed.

    Alias: disable

EXAMPLES:
    cc-cron pause abc12345
    cc-cron disable abc12345
HELP
}

help_resume() {
    cat << 'HELP'
cc-cron resume - Resume a paused job

USAGE:
    cc-cron resume <job-id>

ARGUMENTS:
    job-id      Job ID to resume

DESCRIPTION:
    Re-enable a paused job so it runs on its schedule again.

    Alias: enable

EXAMPLES:
    cc-cron resume abc12345
    cc-cron enable abc12345
HELP
}

help_export() {
    cat << 'HELP'
cc-cron export - Export jobs to JSON

USAGE:
    cc-cron export [job-id] [output-file]

ARGUMENTS:
    job-id       Job ID to export (optional, exports all if omitted)
    output-file  File to write JSON output (optional, stdout if omitted)

DESCRIPTION:
    Export jobs to JSON format for backup or migration.
    The exported JSON includes all job metadata and configuration.

EXAMPLES:
    cc-cron export                    # Export all jobs to stdout
    cc-cron export "" backup.json     # Export all jobs to file
    cc-cron export abc12345 job.json  # Export specific job
HELP
}

help_import() {
    cat << 'HELP'
cc-cron import - Import jobs from JSON

USAGE:
    cc-cron import <file>

ARGUMENTS:
    file    JSON file to import jobs from

DESCRIPTION:
    Import jobs from a JSON file previously exported by cc-cron.
    Requires jq to be installed for JSON parsing.

    Invalid jobs (missing workdir or invalid cron) are skipped with warnings.

EXAMPLES:
    cc-cron import backup.json
HELP
}

help_remove() {
    cat << 'HELP'
cc-cron remove - Remove a scheduled job

USAGE:
    cc-cron remove <job-id>

ARGUMENTS:
    job-id      Job ID to remove

DESCRIPTION:
    Remove a scheduled job permanently. This deletes the crontab entry
    and all associated files (metadata, logs, history, run script).

EXAMPLES:
    cc-cron remove abc12345
HELP
}

help_doctor() {
    cat << 'HELP'
cc-cron doctor - Diagnose issues

USAGE:
    cc-cron doctor

DESCRIPTION:
    Run diagnostics to check for common problems:
    - Data directory existence
    - Crontab access
    - Claude CLI availability
    - Required tools (flock, md5sum)
    - Optional tools (jq for import)
    - Lock file status
    - Job consistency
    - Disk space
    - Directory permissions

EXAMPLES:
    cc-cron doctor
HELP
}

help_version() {
    cat << 'HELP'
cc-cron version - Show version

USAGE:
    cc-cron version

DESCRIPTION:
    Display the current version of cc-cron.

EXAMPLES:
    cc-cron version
HELP
}

# Show help
cmd_help() {
    local topic="${1:-}"

    # Show detailed help for specific command
    case "$topic" in
        add)
            help_add
            return 0
            ;;
        edit)
            help_edit
            return 0
            ;;
        clone)
            help_clone
            return 0
            ;;
        config)
            help_config
            return 0
            ;;
        purge)
            help_purge
            return 0
            ;;
        logs)
            help_logs
            return 0
            ;;
        run)
            help_run
            return 0
            ;;
        show)
            help_show
            return 0
            ;;
        history)
            help_history
            return 0
            ;;
        list)
            help_list
            return 0
            ;;
        next)
            help_next
            return 0
            ;;
        stats)
            help_stats
            return 0
            ;;
        status)
            help_status
            return 0
            ;;
        pause|disable)
            help_pause
            return 0
            ;;
        resume|enable)
            help_resume
            return 0
            ;;
        export)
            help_export
            return 0
            ;;
        import)
            help_import
            return 0
            ;;
        remove)
            help_remove
            return 0
            ;;
        doctor)
            help_doctor
            return 0
            ;;
        version)
            help_version
            return 0
            ;;
        "")
            # No argument - show general help
            ;;
        *)
            echo "Unknown help topic: $topic"
            echo "Run 'cc-cron help' for available commands"
            return 1
            ;;
    esac

    # General help - concise command list
    cat << 'HELP'
cc-cron - Schedule Claude Code commands as cron jobs

USAGE:
    cc-cron <command> [arguments...] [options]

COMMANDS:
    add <cron> <prompt>     Add a scheduled job
    list                    List all scheduled jobs
    status                  Show status overview
    remove <job-id>         Remove a job
    logs <job-id>           Show logs for a job
    pause <job-id>          Pause a job (alias: disable)
    resume <job-id>         Resume a paused job (alias: enable)
    show <job-id>           Show job details
    history <job-id>        Show execution history
    stats [job-id]          Show execution statistics
    run <job-id>            Run a job immediately
    next [job-id]           Show upcoming scheduled runs
    edit <job-id>           Edit a job
    clone <job-id>          Clone a job
    export [job-id]         Export jobs to JSON
    import <file>           Import jobs from JSON
    purge [days]            Clean up old data
    config                  Manage configuration
    doctor                  Diagnose issues
    version                 Show version
    help [command]          Show help

CRON FORMAT:
    * * * * *
    │ │ │ │ │
    │ │ │ │ └─ day of week (0-6, 0=Sunday)
    │ │ │ └─── month (1-12)
    │ │ └───── day of month (1-31)
    │ └─────── hour (0-23)
    └───────── minute (0-59)

ENVIRONMENT:
    CC_WORKDIR         Default working directory
    CC_MODEL           Default model
    CC_PERMISSION_MODE Default permission mode
    CC_TIMEOUT         Default timeout in seconds
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

    _get_tags() {
        local meta_file tags
        for meta_file in ~/.cc-cron/logs/*.meta; do
            [[ -f "$meta_file" ]] || continue
            # Extract tags from meta file
            grep '^tags=' "$meta_file" 2>/dev/null | sed 's/tags=//; s/"//g' | tr ',' '\n'
        done | sort -u
    }

    case ${prev} in
        cc-cron)
            COMPREPLY=($(compgen -W \
                "add list remove logs status pause resume enable disable show history stats run next edit clone export import purge config doctor version completion help" \
                -- "${cur}"))
            ;;
        remove|pause|resume|enable|disable|show|history|run|next|stats)
            COMPREPLY=($(compgen -W "$(_get_job_ids)" -- "${cur}"))
            ;;
        list)
            COMPREPLY=($(compgen -W "$(_get_tags)" -- "${cur}"))
            ;;
        logs)
            if [[ ${#words[@]} -eq 3 ]]; then
                COMPREPLY=($(compgen -W "$(_get_job_ids)" -- "${cur}"))
            elif [[ ${#words[@]} -eq 4 ]]; then
                COMPREPLY=($(compgen -W "--tail -f" -- "${cur}"))
            fi
            ;;
        export)
            if [[ ${#words[@]} -eq 3 ]]; then
                COMPREPLY=($(compgen -W "$(_get_job_ids)" -- "${cur}"))
            fi
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
                COMPREPLY=($(compgen -W \
                "--cron --prompt --workdir --model --permission-mode --timeout --tags" \
                -- "${cur}"))
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
                    COMPREPLY=($(compgen -W "--once --workdir --model --permission-mode --timeout --tags --quiet -q" -- "${cur}"))
                    ;;
            esac
            ;;
        *)
            if [[ " ${words[@]} " =~ " add " ]]; then
                COMPREPLY=($(compgen -W \
                    "--once --workdir --model --permission-mode --timeout --tags --quiet -q" \
                    -- "${cur}"))
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
  --timeout <seconds>         Timeout for job execution (default: \$CC_TIMEOUT or 0, no timeout)
  --tags <tags>               Comma-separated tags for organization (e.g., 'prod,backup')
  --quiet, -q                 Only output the job ID (useful for scripting)" "$EXIT_INVALID_ARGS"
            fi
            local cron_expr="$1"
            local prompt="$2"
            shift 2

            # Parse optional flags
            local recurring="true"
            local job_workdir="$CC_WORKDIR"
            local job_model="$CC_MODEL"
            local job_permission="$CC_PERMISSION_MODE"
            local job_timeout; job_timeout=$(safe_numeric "${CC_TIMEOUT:-0}" "0")
            local quiet="false"
            local job_tags=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --once)
                        recurring="false"
                        shift
                        ;;
                    --workdir)
                        [[ -z "${2:-}" ]] && error "--workdir requires a path" "$EXIT_INVALID_ARGS"
                        validate_workdir "$2"
                        job_workdir="$2"
                        shift 2
                        ;;
                    --model)
                        if [[ $# -lt 2 ]]; then
                            error "--model requires a model name (use empty string to set none)" "$EXIT_INVALID_ARGS"
                        fi
                        job_model="$2"
                        shift 2
                        ;;
                    --permission-mode)
                        [[ -z "${2:-}" ]] && error "--permission-mode requires a mode" "$EXIT_INVALID_ARGS"
                        validate_permission_mode "$2"
                        job_permission="$2"
                        shift 2
                        ;;
                    --timeout)
                        [[ -z "${2:-}" ]] && error "--timeout requires seconds" "$EXIT_INVALID_ARGS"
                        validate_timeout "$2"
                        job_timeout="$2"
                        shift 2
                        ;;
                    --tags)
                        if [[ $# -lt 2 ]]; then
                            error "--tags requires a value (use empty string to set none)" "$EXIT_INVALID_ARGS"
                        fi
                        job_tags="$2"
                        shift 2
                        ;;
                    --quiet|-q)
                        quiet="true"
                        shift
                        ;;
                    *)
                        error "Unknown option: $1" "$EXIT_INVALID_ARGS"
                        ;;
                esac
            done

            cmd_add "$cron_expr" "$prompt" "$recurring" "$job_workdir" \
                "$job_model" "$job_permission" "$job_timeout" "$quiet" "$job_tags"
            ;;
        list)
            ensure_data_dir
            local filter_tag=""
            local json_output="false"
            # Support both positional argument and --tag flag
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --tag)
                        filter_tag="${2:-}"
                        shift 2
                        ;;
                    --json)
                        json_output="true"
                        shift
                        ;;
                    -*)
                        shift
                        ;;
                    *)
                        # Positional argument (tag name)
                        filter_tag="$1"
                        shift
                        ;;
                esac
            done
            cmd_list "$filter_tag" "$json_output"
            ;;
        remove)
            ensure_data_dir
            require_job_id "$command" "$@"
            cmd_remove "$1"
            ;;
        logs)
            ensure_data_dir
            require_job_id "$command" "$@"
            cmd_logs "$1" "$([[ "${2:-}" == "--tail" || "${2:-}" == "-f" ]] && echo true || echo false)"
            ;;
        status)
            ensure_data_dir
            cmd_status
            ;;
        next)
            ensure_data_dir
            cmd_next "${1:-}" "${2:-}"
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
        stats)
            ensure_data_dir
            cmd_stats "${1:-}"
            ;;
        run)
            ensure_data_dir
            require_job_id "$command" "$@"
            cmd_run "$1"
            ;;
        edit)
            ensure_data_dir
            require_job_id "$command" "$@"
            cmd_edit "$1" "${@:2}"
            ;;
        clone)
            ensure_data_dir
            require_job_id "$command" "$@"
            cmd_clone "$1" "${@:2}"
            ;;
        export)
            ensure_data_dir
            cmd_export "${1:-}" "${2:-}"
            ;;
        import)
            ensure_data_dir
            [[ $# -lt 1 ]] && error "Usage: cc-cron import <file>" "$EXIT_INVALID_ARGS"
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
            cmd_help "${1:-}"
            ;;
        *)
            error "Unknown command: ${command}. Run 'cc-cron help' for usage." "$EXIT_INVALID_ARGS"
            ;;
    esac
}

# Only run main if not being sourced for testing
if [[ "${CC_CRON_TEST_MODE:-0}" != "1" ]]; then
    main "$@"
fi
