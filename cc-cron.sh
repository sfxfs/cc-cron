#!/usr/bin/env bash
#
# cc-cron - Schedule Claude Code commands as cron jobs
#
# Usage:
#   cc-cron add <cron-expression> <prompt> [--recurring]
#   cc-cron list
#   cc-cron remove <job-id>
#   cc-cron logs <job-id>
#
# Examples:
#   cc-cron add "0 9 * * 1-5" "Run daily tests" --recurring
#   cc-cron add "30 14 28 2 *" "One-time reminder"  # one-shot
#   cc-cron list
#   cc-cron remove abc123
#

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
CRON_COMMENT_PREFIX="CC-CRON:"
CLAUDE_CMD="claude -p"  # Non-interactive mode

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
    local recurring="${3:-true}"  # Default to recurring

    validate_cron "$cron_expr"

    local job_id
    job_id=$(generate_job_id)
    local log_file="${LOG_DIR}/${job_id}.log"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    ensure_log_dir

    # Build the command
    # Claude Code command with logging
    local claude_full_cmd="cd ${SCRIPT_DIR} && ${CLAUDE_CMD} \"${prompt}\" >> \"${log_file}\" 2>&1"

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
EOF

    success "Created cron job: ${job_id}"
    info "Schedule: ${cron_expr}"
    info "Recurring: ${recurring}"
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

# Show help
cmd_help() {
    cat << 'HELP'
cc-cron - Schedule Claude Code commands as cron jobs

USAGE:
    cc-cron <command> [options]

COMMANDS:
    add <cron> <prompt> [--once]    Add a scheduled job
        <cron>   - Standard 5-field cron expression (minute hour day month weekday)
        <prompt> - The prompt to send to Claude Code
        --once   - Create a one-shot job (default is recurring)

    list                            List all scheduled jobs
    remove <job-id>                 Remove a scheduled job
    logs <job-id>                   Show logs for a job
    help                            Show this help message

CRON EXPRESSION FORMAT:
    ┌───────────── minute (0 - 59)
    │ ┌───────────── hour (0 - 23)
    │ │ ┌───────────── day of month (1 - 31)
    │ │ │ ┌───────────── month (1 - 12)
    │ │ │ │ ┌───────────── day of week (0 - 6, 0 = Sunday)
    │ │ │ │ │
    * * * * *

EXAMPLES:
    # Run every weekday at 9am
    cc-cron add "0 9 * * 1-5" "Run the daily build and send a summary"

    # Run every hour
    cc-cron add "0 * * * *" "Check for new issues and report"

    # One-time reminder at specific time
    cc-cron add "30 14 15 3 *" "Review the quarterly report" --once

    # List all jobs
    cc-cron list

    # Remove a job
    cc-cron remove abc123

    # View job logs
    cc-cron logs abc123

NOTES:
    - Jobs run in non-interactive mode using 'claude -p'
    - Logs are stored in: ./logs/<job-id>.log
    - Use absolute paths in prompts for file operations
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
                error "Usage: cc-cron add <cron-expression> <prompt> [--once]"
            fi
            local cron_expr="$1"
            local prompt="$2"
            shift 2
            local recurring="true"
            if [[ "${1:-}" == "--once" ]]; then
                recurring="false"
            fi
            cmd_add "$cron_expr" "$prompt" "$recurring"
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
        help|--help|-h)
            cmd_help
            ;;
        *)
            error "Unknown command: ${command}. Run 'cc-cron help' for usage."
            ;;
    esac
}

main "$@"