# cc-cron

Schedule Claude Code commands as cron jobs.

## Installation

```bash
# Clone or download the script
chmod +x cc-cron.sh

# Optional: Add to PATH
ln -s $(pwd)/cc-cron.sh ~/.local/bin/cc-cron
```

## Usage

### Add a Scheduled Job

```bash
./cc-cron.sh add <cron-expression> <prompt> [options]
```

**Options:**

| Option | Description |
|--------|-------------|
| `--once` | Create a one-shot job (default: recurring) |
| `--workdir <path>` | Working directory for this job |
| `--model <name>` | Model to use: sonnet, opus, haiku, etc. |
| `--permission-mode <mode>` | Permission mode: acceptEdits, auto, default |

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

### Check Status

```bash
./cc-cron.sh status
```

Shows execution status (success/failure), timestamps, and a summary of recent job results.

## Per-Job vs Global Configuration

Each job can have its own settings specified via command-line options. When not specified, jobs fall back to environment variable defaults.

| Setting | Per-Job Option | Environment Variable | Default |
|---------|----------------|---------------------|---------|
| Working directory | `--workdir` | `CC_WORKDIR` | `$HOME` |
| Model | `--model` | `CC_MODEL` | Claude's default |
| Permission mode | `--permission-mode` | `CC_PERMISSION_MODE` | `bypassPermissions` |

**Priority:** Per-job option > Environment variable > Built-in default

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
- One-shot jobs require manual cleanup after execution