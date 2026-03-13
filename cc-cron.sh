#!/usr/bin/env bash
#
# cc-cron - Schedule Claude Code commands as cron jobs
#
# Usage:
#   cc-cron add <cron-expression> <prompt> [options]
#   cc-cron list
#   cc-cron remove <job-id>
#   cc-cron logs <job-id>
#
# Examples:
#   cc-cron add "0 9 * * 1-5" "Run daily tests"
#   cc-cron add "0 * * * *" "Check issues" --model sonnet --workdir /path/to/project
#   cc-cron add "30 14 28 2 *" "One-time reminder" --once
#   cc-cron list
#   cc-cron remove abc123
#

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
CRON_COMMENT_PREFIX="CC-CRON:"
CLAUDE_CMD="claude -p"  # Non-interactive mode

# Environment configuration (can be overridden)
CC_WORKDIR="${CC_WORKDIR:-$SCRIPT_DIR}"
CC_PERMISSION_MODE="${CC_PERMISSION_MODE:-acceptEdits}"
CC_MODEL="${CC_MODEL:-}"

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
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Generate unique job ID
generate_job_id() {
    head /dev/urandom | tr -dc 'a-z0-9' | head -c 8
}

# Validate cron expression (basic validation)
validate_cron() {
    local cron="$1"
    local fields
    fields=$(echo "$cron" | awk '{print NF}')
    if [[ "$fields" -ne 5 ]]; then
        error "Invalid cron expression: $cron (expected 5 fields: minute hour day month weekday)"
    fi
}

# Ensure log directory exists
ensure_log_dir() {
    mkdir -p "$LOG_DIR"
}

# Add a new cron job
cmd_add() {
    local cron_expr="$1"
    local prompt="$2"
    local recurring="${3:-true}"
    local job_workdir="${4:-$CC_WORKDIR}"
    local job_model="${5:-$CC_MODEL}"
    local job_permission="${6:-$CC_PERMISSION_MODE}"

    validate_cron "$cron_expr"

    local job_id
    job_id=$(generate_job_id)
    local log_file="${LOG_DIR}/${job_id}.log"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    ensure_log_dir

    # Build the command with per-job or environment options
    local claude_opts="-p"
    [[ -n "$job_model" ]] && claude_opts="$claude_opts --model $job_model"
    [[ "$job_permission" != "default" ]] && claude_opts="$claude_opts --permission-mode $job_permission"

    local claude_full_cmd="cd ${job_workdir} && claude ${claude_opts} \"${prompt}\" >> \"${log_file}\" 2>&1"

    # Create the cron entry with marker comment for identification
    local cron_entry="${cron_expr} ${claude_full_cmd}  # ${CRON_COMMENT_PREFIX}${job_id}:recurring=${recurring}:prompt=${prompt:0:30}"

    # Add to crontab (grep -v returns 1 when no matches, so we need || true)
    (crontab -l 2>/dev/null | { grep -v "${CRON_COMMENT_PREFIX}${job_id}" || true; }; echo "$cron_entry") | crontab -

    # Save job metadata
    cat > "${LOG_DIR}/${job_id}.meta" << EOF
id="${job_id}"
created="${timestamp}"
cron="${cron_expr}"
recurring="${recurring}"
prompt="${prompt}"
workdir="${job_workdir}"
model="${job_model}"
permission_mode="${job_permission}"
EOF

    success "Created cron job: ${job_id}"
    info "Schedule: ${cron_expr}"
    info "Recurring: ${recurring}"
    info "Workdir: ${job_workdir}"
    [[ -n "$job_model" ]] && info "Model: ${job_model}"
    info "Permission: ${job_permission}"
    info "Prompt: ${prompt}"
    info "Log file: ${log_file}"

    # If one-shot job, note that manual cleanup is needed after execution
    if [[ "$recurring" == "false" ]]; then
        warn "One-shot job. Remember to run 'cc-cron remove ${job_id}' after execution."
    fi
}

# List all cc-cron jobs
cmd_list() {
    local found=0

    echo "Scheduled Claude Code Cron Jobs:"
    echo "================================="
    echo

    while IFS= read -r line; do
        if [[ "$line" == *"${CRON_COMMENT_PREFIX}"* ]]; then
            found=1
            # Extract job ID from comment
            local job_id
            job_id=$(echo "$line" | grep -oP "${CRON_COMMENT_PREFIX}\K[a-z0-9]+")

            # Read metadata if exists
            local meta_file="${LOG_DIR}/${job_id}.meta"
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
    done < <(crontab -l 2>/dev/null)

    if [[ "$found" -eq 0 ]]; then
        info "No scheduled jobs found."
    fi
}

# Remove a cron job by ID
cmd_remove() {
    local job_id="$1"
    local found=0

    # Remove from crontab
    if crontab -l 2>/dev/null | grep -q "${CRON_COMMENT_PREFIX}${job_id}"; then
        found=1
        crontab -l 2>/dev/null | { grep -v "${CRON_COMMENT_PREFIX}${job_id}" || true; } | crontab -
        success "Removed cron job: ${job_id}"
    fi

    # Remove metadata and log files
    local meta_file="${LOG_DIR}/${job_id}.meta"
    local log_file="${LOG_DIR}/${job_id}.log"

    if [[ -f "$meta_file" ]]; then
        rm "$meta_file"
        info "Removed metadata: ${meta_file}"
    fi

    if [[ -f "$log_file" ]]; then
        rm "$log_file"
        info "Removed log file: ${log_file}"
    fi

    if [[ "$found" -eq 0 ]]; then
        error "Job not found: ${job_id}"
    fi
}

# Show logs for a job
cmd_logs() {
    local job_id="$1"
    local log_file="${LOG_DIR}/${job_id}.log"

    if [[ -f "$log_file" ]]; then
        info "Logs for job ${job_id}:"
        echo "================================="
        cat "$log_file"
    else
        error "No logs found for job: ${job_id}"
    fi
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

    # Show recent logs
    echo "Recent log activity:"
    echo "--------------------"
    for meta_file in "${LOG_DIR}"/*.meta; do
        [[ -f "$meta_file" ]] || continue
        source "$meta_file"
        local log_file="${LOG_DIR}/${id}.log"
        if [[ -f "$log_file" ]]; then
            local lines last_run
            lines=$(wc -l < "$log_file")
            last_run=$(stat -c %y "$log_file" 2>/dev/null | cut -d. -f1)
            echo "  ${id}: ${lines} log lines, last run: ${last_run}"
        fi
    done
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
          --once                      Create a one-shot job (default: recurring)
          --workdir <path>            Working directory for this job
          --model <name>              Model to use: sonnet, opus, etc.
          --permission-mode <mode>    Permission mode (acceptEdits, auto, default)

    list                            List all scheduled jobs
    status                          Show status overview and log activity
    remove <job-id>                 Remove a scheduled job
    logs <job-id>                   Show logs for a job
    help                            Show this help message

ENVIRONMENT VARIABLES (used as defaults when not specified per-job):
    CC_WORKDIR          Working directory (default: script directory)
    CC_PERMISSION_MODE  Permission mode (default: acceptEdits)
    CC_MODEL            Model to use (default: unset, uses Claude's default)

CRON EXPRESSION FORMAT:
    ┌───────────── minute (0 - 59)
    │ ┌───────────── hour (0 - 23)
    │ │ ┌───────────── day of month (1 - 31)
    │ │ │ ┌───────────── month (1 - 12)
    │ │ │ │ ┌───────────── day of week (0 - 6, 0 = Sunday)
    │ │ │ │ │
    * * * * *

EXAMPLES:
    # Run every weekday at 9am with default settings
    cc-cron add "0 9 * * 1-5" "Run the daily build and send a summary"

    # Run with specific model and working directory
    cc-cron add "0 * * * *" "Check for issues" --model sonnet --workdir /home/user/myproject

    # One-time reminder with custom permission mode
    cc-cron add "30 14 15 3 *" "Review the report" --once --permission-mode auto

    # List all jobs
    cc-cron list

    # Check status
    cc-cron status

    # Remove a job
    cc-cron remove abc123

    # View job logs
    cc-cron logs abc123

NOTES:
    - Jobs run in non-interactive mode using 'claude -p'
    - Logs are stored in: ./logs/<job-id>.log
    - Per-job settings override environment variable defaults
    - Cron jobs run with a limited environment; ensure Claude Code
      is in PATH or specify the full path
HELP
}

# Main entry point
main() {
    ensure_log_dir

    local command="${1:-help}"
    shift || true

    case "$command" in
        add)
            if [[ $# -lt 2 ]]; then
                error "Usage: cc-cron add <cron-expression> <prompt> [options]

Options:
  --once                      Create a one-shot job (default: recurring)
  --workdir <path>            Working directory (default: \$CC_WORKDIR or script dir)
  --model <name>              Model to use: sonnet, opus, etc. (default: \$CC_MODEL)
  --permission-mode <mode>    Permission mode (default: \$CC_PERMISSION_MODE or acceptEdits)"
            fi
            local cron_expr="$1"
            local prompt="$2"
            shift 2

            # Parse optional flags
            local recurring="true"
            local job_workdir="$CC_WORKDIR"
            local job_model="$CC_MODEL"
            local job_permission="$CC_PERMISSION_MODE"

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
                    *)
                        error "Unknown option: $1"
                        ;;
                esac
            done

            cmd_add "$cron_expr" "$prompt" "$recurring" "$job_workdir" "$job_model" "$job_permission"
            ;;
        list)
            cmd_list
            ;;
        remove)
            if [[ $# -lt 1 ]]; then
                error "Usage: cc-cron remove <job-id>"
            fi
            cmd_remove "$1"
            ;;
        logs)
            if [[ $# -lt 1 ]]; then
                error "Usage: cc-cron logs <job-id>"
            fi
            cmd_logs "$1"
            ;;
        status)
            cmd_status
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            error "Unknown command: ${command}. Run 'cc-cron help' for usage."
            ;;
    esac
}

main "$@"