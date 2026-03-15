# cc-cron

[English](README.md) | [简体中文](README.zh-CN.md)

Schedule Claude Code commands as cron jobs.

## Installation

```bash
# Clone or download the script
chmod +x cc-cron.sh

# Optional: Add to PATH
ln -s $(pwd)/cc-cron.sh ~/.local/bin/cc-cron

# Optional: Enable bash completion (add to ~/.bashrc)
eval "$(cc-cron completion)"
```

## Usage

### Add a Scheduled Job

```bash
./cc-cron.sh add <cron-expression> <prompt> [options]
```

**Options:**

| Option | Description |
|--------|-------------|
| `--once` | Create a one-shot job (auto-removes after successful execution) |
| `--workdir <path>` | Working directory for this job |
| `--model <name>` | Model to use: sonnet, opus, haiku, etc. |
| `--permission-mode <mode>` | Permission mode: acceptEdits, auto, default |
| `--timeout <seconds>` | Timeout for job execution (0 = no timeout, default) |

**Examples:**

```bash
# Run every weekday at 9am with default settings
./cc-cron.sh add "0 9 * * 1-5" "Run daily tests and report results"

# Run with specific model and working directory
./cc-cron.sh add "0 * * * *" "Check for issues" --model sonnet --workdir /home/user/myproject

# One-time reminder with custom permission mode
./cc-cron.sh add "30 14 28 2 *" "Quarterly review reminder" --once --permission-mode auto
```

### List Jobs

```bash
./cc-cron.sh list
```

### View Logs

```bash
./cc-cron.sh logs <job-id>
```

### Remove a Job

```bash
./cc-cron.sh remove <job-id>
```

### Pause a Job

Temporarily disable a scheduled job without removing it:

```bash
./cc-cron.sh pause <job-id>
```

### Resume a Job

Re-enable a paused job:

```bash
./cc-cron.sh resume <job-id>
```

### Show Job Details

Display full information for a specific job:

```bash
./cc-cron.sh show <job-id>
```

This displays:
- Job metadata (ID, created, schedule, recurring, workdir, model, permission)
- Full prompt text
- Last execution status (if available)
- Execution statistics (total runs, success/failure counts)

### View Execution History

Show execution history for a job:

```bash
./cc-cron.sh history <job-id> [lines]
```

Default is 20 lines. Each entry shows start time, end time, and status.

### Run a Job Immediately

Execute a job right now (useful for testing):

```bash
./cc-cron.sh run <job-id>
```

This runs the job synchronously and displays the output.

### Edit a Job

Modify an existing job's settings:

```bash
./cc-cron.sh edit <job-id> [options]
```

**Options:**

| Option | Description |
|--------|-------------|
| `--cron <expr>` | Update cron schedule |
| `--prompt <text>` | Update prompt |
| `--workdir <path>` | Update working directory |
| `--model <name>` | Update model |
| `--permission-mode <mode>` | Update permission mode |
| `--timeout <seconds>` | Update timeout |

**Example:**
```bash
# Change schedule to run every hour
./cc-cron.sh edit myjob --cron "0 * * * *"

# Update the prompt
./cc-cron.sh edit myjob --prompt "New prompt text"
```

### Export Jobs

Export jobs to JSON format for backup or migration:

```bash
# Export all jobs to stdout
./cc-cron.sh export

# Export all jobs to a file
./cc-cron.sh export "" backup.json

# Export a specific job
./cc-cron.sh export myjob myjob.json
```

The exported JSON includes:
- Job metadata (ID, created, schedule, recurring, etc.)
- Full prompt text
- Configuration (workdir, model, permission mode, timeout)
- Pause state

### Import Jobs

Import jobs from a JSON file:

```bash
./cc-cron.sh import backup.json
```

**Note:** Requires `jq` for JSON parsing. Install with:
- Ubuntu/Debian: `apt-get install jq`
- macOS: `brew install jq`

### Purge Old Data

Clean up old logs and orphaned files:

```bash
# Purge files older than 7 days (default)
./cc-cron.sh purge

# Purge files older than 30 days
./cc-cron.sh purge 30

# Dry-run to see what would be deleted
./cc-cron.sh purge --dry-run
```

The purge command removes:
- Log files older than the specified days
- History files older than the specified days
- Orphaned files (files for jobs that no longer exist in crontab)

### Configuration Management

Manage default settings via configuration file:

```bash
# Show current configuration
./cc-cron.sh config list

# Set default values
./cc-cron.sh config set workdir /home/user/myproject
./cc-cron.sh config set model sonnet
./cc-cron.sh config set permission_mode auto
./cc-cron.sh config set timeout 300

# Remove a configuration value
./cc-cron.sh config unset model
```

Configuration is stored in `~/.cc-cron/config`. Valid keys:
- `workdir` - Default working directory
- `model` - Default model (sonnet, opus, haiku)
- `permission_mode` - Default permission mode
- `timeout` - Default timeout in seconds

**Priority:** Command-line options > Config file > Environment variables > Built-in defaults

### Diagnose Issues

Run diagnostics to check for common problems:

```bash
./cc-cron.sh doctor
```

The doctor command checks:
- Data directory existence
- Crontab access
- Claude CLI availability
- Required tools (flock, md5sum)
- Optional tools (jq for import)
- Lock file status
- Job consistency
- Disk space
- Directory permissions

### Check Version

```bash
./cc-cron.sh version
```

### Bash Completion

Enable tab completion for commands and job IDs:

```bash
# Add to ~/.bashrc
eval "$(cc-cron completion)"
```

**Features:**
- Command completion: `add`, `list`, `remove`, `logs`, `status`, `pause`, `resume`, `show`, `history`, `run`, `edit`, `export`, `import`, `purge`, `config`, `doctor`, `version`, `completion`
- Job ID completion for `remove`, `logs`, `pause`, `resume`, `show`, `history`, `run`, `edit`, and `export` commands
- Model names: `sonnet`, `opus`, `haiku`
- Permission modes: `bypassPermissions`, `acceptEdits`, `auto`, `default`
- Directory completion for `--workdir`
- Common cron expression suggestions for `add`

### Check Status

```bash
./cc-cron.sh status
```

Shows execution status (running/success/failure), timestamps, and a summary of recent job results.

**Status values:**
- `RUNNING` - Job is currently executing
- `SUCCESS` - Job completed successfully
- `FAILED` - Job exited with non-zero code
- `UNKNOWN` - No status information available

## Per-Job vs Global Configuration

Each job can have its own settings specified via command-line options. When not specified, jobs fall back to config file, then environment variable defaults.

| Setting | Per-Job Option | Config File | Environment Variable | Default |
|---------|----------------|-------------|---------------------|---------|
| Working directory | `--workdir` | `workdir` | `CC_WORKDIR` | `$HOME` |
| Model | `--model` | `model` | `CC_MODEL` | Claude's default |
| Permission mode | `--permission-mode` | `permission_mode` | `CC_PERMISSION_MODE` | `bypassPermissions` |
| Timeout | `--timeout` | `timeout` | `CC_TIMEOUT` | `0` (no timeout) |

**Priority:** Per-job option > Config file > Environment variable > Built-in default

## Cron Expression Format

```
┌───────────── minute (0 - 59)
│ ┌───────────── hour (0 - 23)
│ │ ┌───────────── day of month (1 - 31)
│ │ │ ┌───────────── month (1 - 12)
│ │ │ │ ┌───────────── day of week (0 - 6)
│ │ │ │ │
* * * * *
```

## Examples

### Daily Code Review at 5 PM
```bash
./cc-cron.sh add "0 17 * * *" "Review today's commits in the main branch"
```

### Hourly Status Check with Specific Model
```bash
./cc-cron.sh add "7 * * * *" "Check system status and report any issues" --model sonnet
```

### Weekly Report Every Monday with Custom Workdir
```bash
./cc-cron.sh add "0 9 * * 1" "Generate weekly summary report" --workdir /home/user/reports
```

### Project-Specific Task
```bash
./cc-cron.sh add "0 12 * * *" "Run tests in the backend project" \
  --workdir /home/user/backend \
  --model opus \
  --permission-mode auto
```

## Notes

- Jobs run non-interactively using `claude -p`
- Jobs automatically source `~/.bashrc` and `~/.bash_profile` to load API keys
- Default permission mode is `bypassPermissions` (no permission prompts)
- Data stored in `~/.cc-cron/`:
  - `logs/` - Job logs and status files
  - `locks/` - Directory lock files
  - `run-*.sh` - Generated job runner scripts
- Directory locking prevents concurrent Claude executions in the same directory
- Per-job settings are saved and persist across restarts
- One-shot jobs (`--once`) auto-remove after successful execution; on failure, they remain for debugging/retry

## Development

### Running Tests

```bash
make test
```

### Linting

```bash
make lint
```

### Running All Checks

```bash
make check
```

### Installation

```bash
make install
```
