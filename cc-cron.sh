#!/usr/bin/env bash
set -euo pipefail
readonly EXIT_SUCCESS=0
readonly EXIT_ERROR=1
readonly EXIT_NOT_FOUND=2
readonly EXIT_INVALID_ARGS=3
DATA_DIR="${DATA_DIR:-${HOME}/.cc-cron}"
LOG_DIR="${LOG_DIR:-${DATA_DIR}/logs}"
LOCK_DIR="${LOCK_DIR:-${DATA_DIR}/locks}"
CRON_COMMENT_PREFIX="CC-CRON:"
CC_WORKDIR="${CC_WORKDIR:-$HOME}"
CC_PERMISSION_MODE="${CC_PERMISSION_MODE:-bypassPermissions}"
CC_MODEL="${CC_MODEL:-}"
_CRONTAB_CACHE=""
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() {
    local message="$1"
    local exit_code="${2:-$EXIT_ERROR}"
    echo -e "${RED}[ERROR]${NC} ${message}" >&2
    exit "$exit_code"
}
ensure_data_dir() {
    mkdir -p "$LOG_DIR" "$LOCK_DIR"
}
get_meta_file() { echo "${LOG_DIR}/${1}.meta"; }
get_log_file() { echo "${LOG_DIR}/${1}.log"; }
get_status_file() { echo "${LOG_DIR}/${1}.status"; }
get_run_script() { echo "${DATA_DIR}/run-${1}.sh"; }
validate_range() {
    local value="$1" min="$2" max="$3" context="$4"
    if [[ "$value" -lt "$min" || "$value" -gt "$max" ]]; then
        error "Invalid value '$value' for $context (must be $min-$max)"
    fi
}
remove_file() {
    [[ -f "$1" ]] && { rm "$1"; info "Removed $2: ${1}"; }
}
generate_job_id() {
    local job_id
    local random_bytes
    local _
    for _ in {1..10}; do
        random_bytes=$(head -c 100 /dev/urandom | tr -dc 'a-z0-9')
        job_id="${random_bytes:0:8}"
        [[ ! -f "$(get_meta_file "$job_id")" ]] && echo "$job_id" && return
    done
    error "Failed to generate unique job ID after 10 attempts"
}
validate_cron_field() {
    local value="$1" min="$2" max="$3" field_name="$4"
    [[ "$value" == "*" ]] && return 0
    case "$value" in
        */*)
            local step="${value#*/}"
            step="${step%%/*}"
            [[ "$step" =~ ^[0-9]+$ ]] || error "Invalid step value in '$value' for $field_name"
            [[ "$step" -ge 1 && "$step" -le "$max" ]] && return 0
            error "Invalid step value '$step' in '$value' for $field_name (must be 1-$max)"
            ;;
    esac
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
    [[ "$value" =~ ^[0-9]+$ ]] || error "Invalid cron field value '$value' for $field_name"
    validate_range "$value" "$min" "$max" "$field_name"
}
validate_cron() {
    local cron="$1"
    local -a fields
    read -ra fields <<< "$cron"
    if [[ ${#fields[@]} -ne 5 ]]; then
        error "Invalid cron expression: $cron (expected 5 fields: minute hour day month weekday)"
    fi
    validate_cron_field "${fields[0]}" 0 59 "minute"
    validate_cron_field "${fields[1]}" 0 23 "hour"
    validate_cron_field "${fields[2]}" 1 31 "day of month"
    validate_cron_field "${fields[3]}" 1 12 "month"
    validate_cron_field "${fields[4]}" 0 6 "day of week"
}
validate_workdir() {
    [[ -d "$1" ]] || error "Directory not found: $1"
}
crontab_add_entry() {
    local entry="$1"
    (crontab -l 2>/dev/null; echo "$entry") | crontab -
    invalidate_crontab_cache
}
get_crontab() {
    if [[ -z "${_CRONTAB_CACHE:-}" ]]; then
        _CRONTAB_CACHE=$(crontab -l 2>/dev/null) || _CRONTAB_CACHE=""
    fi
    printf '%s\n' "$_CRONTAB_CACHE"
}
invalidate_crontab_cache() {
    _CRONTAB_CACHE=""
}
crontab_has_entry() {
    local pattern="$1"
    get_crontab | grep -q "$pattern"
}
crontab_remove_entry() {
    local pattern="$1"
    crontab -l 2>/dev/null | { grep -v "$pattern" || true; } | crontab -
    invalidate_crontab_cache
}
get_lock_file() {
    local dir="$1"
    local dir_hash
    dir_hash=$(echo -n "$dir" | md5sum | cut -d' ' -f1)
    echo "${LOCK_DIR}/${dir_hash}.lock"
}
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
    local claude_opts="-p"
    [[ -n "$job_model" ]] && claude_opts="$claude_opts --model $job_model"
    [[ "$job_permission" != "default" ]] && claude_opts="$claude_opts --permission-mode $job_permission"
    local safe_prompt="${prompt//\'/\'\\\'\'}"
    local run_script; run_script=$(get_run_script "$job_id")
    local current_path="$PATH"
    cat > "$run_script" << RUNEOF
#!/usr/bin/env bash
set -e
export PATH="${current_path}"
LOG_FILE="${log_file}"
STATUS_FILE="${status_file}"
LOCK_FILE="${lock_file}"
WORKDIR="${job_workdir}"
JOB_ID="${job_id}"
RECURRING="${recurring}"
TIMEOUT="${job_timeout}"
cleanup() {
    exec 9>&-
}
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
    if [[ "\$RECURRING" == "false" ]]; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] AUTO-REMOVED: One-shot job completed successfully" >> "\$LOG_FILE"
        (crontab -l 2>/dev/null | grep -v "CC-CRON:\${JOB_ID}:" || true) | crontab -
        rm -f "\$LOG_FILE" "\$STATUS_FILE" "${meta_file}" "\$0"
    fi
else
    echo "status=\"failed\"" >> "\$STATUS_FILE"
    if [[ "\$RECURRING" == "false" ]]; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] One-shot job failed - keeping job for retry. Run 'cc-cron remove \${JOB_ID}' to clean up." >> "\$LOG_FILE"
    fi
fi
RUNEOF
    chmod +x "$run_script"
    local cron_entry="${cron_expr} ${run_script}  # ${CRON_COMMENT_PREFIX}${job_id}:recurring=${recurring}:prompt=${prompt:0:30}"
    crontab_add_entry "$cron_entry"
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
cmd_list() {
    local found=0
    echo "Scheduled Claude Code Cron Jobs:"
    echo "================================="
    echo
    local crontab_content
    crontab_content=$(get_crontab) || return 0
    while IFS= read -r line; do
        if [[ "$line" == *"${CRON_COMMENT_PREFIX}"* ]]; then
            found=1
            local job_id temp
            temp="${line#*"${CRON_COMMENT_PREFIX}"}"
            job_id="${temp%%:*}"
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
cmd_remove() {
    local job_id="$1"
    local found=0
    if crontab_has_entry "${CRON_COMMENT_PREFIX}${job_id}"; then
        found=1
        crontab_remove_entry "${CRON_COMMENT_PREFIX}${job_id}"
        success "Removed cron job: ${job_id}"
    fi
    remove_file "$(get_meta_file "$job_id")" "metadata"
    remove_file "$(get_log_file "$job_id")" "log file"
    remove_file "$(get_status_file "$job_id")" "status file"
    remove_file "$(get_run_script "$job_id")" "run script"
    if [[ "$found" -eq 0 ]]; then
        error "Job not found: ${job_id}"
    fi
}
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
cmd_status() {
    info "CC-Cron Status Report"
    echo "======================"
    echo
    if ! crontab -l &>/dev/null; then
        warn "No crontab configured for current user"
        return
    fi
    local job_count
    job_count=$(crontab -l 2>/dev/null | { grep "${CRON_COMMENT_PREFIX}" || true; } | wc -l)
    echo "Total scheduled jobs: ${job_count}"
    echo
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
cmd_help() {
    cat << 'HELP'
cc-cron - Schedule Claude Code commands as cron jobs
Usage: cc-cron <command> [options]
Commands:
  add <cron> <prompt>
      [--once] [--workdir <path>] [--model <name>]
      [--permission-mode <mode>] [--timeout <seconds>]
  list | status | remove <job-id> | logs <job-id> | completion | help
Defaults from environment: CC_WORKDIR, CC_PERMISSION_MODE, CC_MODEL, CC_TIMEOUT
Cron format: minute hour day month weekday (5 fields)
HELP
}
cmd_completion() {
    cat << 'COMPLETION'
_cc_cron_completion() {
    local cur prev words cword
    _init_completion || return
    local commands="add list remove logs status completion help"
    local opts="--once --workdir --model --permission-mode --timeout"
    _get_job_ids() { for meta_file in ${LOG_DIR:-${HOME}/.cc-cron/logs}/*.meta; do [[ -f "$meta_file" ]] && basename "$meta_file" .meta; done; }
    case ${prev} in
        cc-cron) COMPREPLY=($(compgen -W "${commands}" -- "${cur}"));;
        remove|logs) COMPREPLY=($(compgen -W "$(_get_job_ids)" -- "${cur}"));;
        --model) COMPREPLY=($(compgen -W "sonnet opus haiku" -- "${cur}"));;
        --permission-mode) COMPREPLY=($(compgen -W "bypassPermissions acceptEdits auto default" -- "${cur}"));;
        --workdir)
            _filedir -d
            ;;
        *)
            [[ " ${words[*]} " == *" add "* ]] && COMPREPLY=($(compgen -W "${opts}" -- "${cur}"))
            ;;
    esac
}
complete -F _cc_cron_completion cc-cron
COMPLETION
}
main() {
    local command="${1:-help}"
    shift || true
    case "$command" in
        add)
            ensure_data_dir
            if [[ $# -lt 2 ]]; then
                error "Usage: cc-cron add <cron-expression> <prompt> [--once] [--workdir <path>] [--model <name>] [--permission-mode <mode>] [--timeout <seconds>]. Run 'cc-cron help' for option details."
            fi
            local cron_expr="$1"
            local prompt="$2"
            shift 2
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
if [[ "${CC_CRON_TEST_MODE:-0}" != "1" ]]; then
    main "$@"
fi
