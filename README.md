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
# Run every weekday at 9am
./cc-cron.sh add "0 9 * * 1-5" "Run daily tests and report results"

# One-time execution
./cc-cron.sh add "30 14 28 2 *" "Quarterly review reminder" --once
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

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CC_WORKDIR` | Script directory | Working directory for Claude Code |
| `CC_PERMISSION_MODE` | `acceptEdits` | Permission mode (acceptEdits, auto, default) |
| `CC_MODEL` | (unset) | Model to use (sonnet, opus, etc.) |

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

### Hourly Status Check
```bash
./cc-cron.sh add "7 * * * *" "Check system status and report any issues"
```

### Weekly Report Every Monday
```bash
./cc-cron.sh add "0 9 * * 1" "Generate weekly summary report"
```

## Notes

- Jobs run non-interactively using `claude -p`
- Use absolute paths in prompts for file operations
- Logs are stored in `./logs/<job-id>.log`
- One-shot jobs require manual cleanup after execution