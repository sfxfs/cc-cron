# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.3.3] - 2025-03-16

### Fixed
- Correct bash completion for edit and clone commands (clone was duplicated causing option completion to fail)

### Documentation
- Add CHANGELOG.md to track version history
- Add help documentation for export, import, remove, doctor, and version commands

### Tests
- Add test to verify edit/clone options are included in completion
- Add tests for new help functions

## [2.3.2] - 2025-03-16

### Fixed
- Check job exists before checking pause state in `cmd_resume` for better error messages
- Add explicit exit codes to all error calls for consistent error handling
- Use `EXIT_INVALID_ARGS` for validation errors consistently

### Documentation
- Add help documentation for pause/resume commands

### Tests
- Update tests to verify specific exit codes throughout test suite
- Add tests for exit codes in import and purge commands

## [2.3.1] - 2025-03-16

### Fixed
- Use `EXIT_INVALID_ARGS` for unknown option and command errors
- Add stats command to job ID completion
- Support positional tag argument in list command

### Documentation
- Document exit codes in README

### Tests
- Verify `EXIT_INVALID_ARGS` for argument errors
- Add help command tests for clone, purge, list, status

## [2.3.0] - 2025-03-15

### Added
- Add tag completion for list command
- Add `--tags` option for organizing and filtering jobs

### Fixed
- Improve error messages for logs and history commands
- Use proper exit codes for job not found errors

### Documentation
- Document tags feature in README
- Add help documentation for list and status commands
- Add list, next, and status to main help output

### Tests
- Add test for exporting jobs with tags
- Add test for cloning jobs with tags
- Add test for tag preservation during import

## [2.2.1] - 2025-03-15

### Fixed
- Handle hour step patterns and weekday ranges in `calculate_next_run`
- Handle step patterns in `calculate_next_run`
- Reset optional fields before sourcing meta files in loops
- Remove `bc` dependency in `cmd_purge`
- Handle invalid JSON and cron gracefully in import

### Added
- Add job tags for organization and filtering

### Tests
- Add test for `cmd_stats` with malformed history entries
- Add tests for `calculate_next_run` function

### Fixed
- Add macOS compatibility for duration calculation in stats

### Documentation
- Add documentation for stats and next commands

## [2.2.0] - 2025-03-14

### Added
- Add `stats` command for execution statistics
- Add `next` command to show upcoming scheduled runs

### Fixed
- Correct weekly schedule condition in `calculate_next_run()`

### Tests
- Add comprehensive tests for `calculate_next_run` function
- Add tests for `next` command

## [1.9.5] - 2025-03-14

### Tests
- Add tests for `cmd_config` unset functionality

## [1.9.4] - 2025-03-14

### Tests
- Add test for `cmd_run` with missing run script

## [1.9.3] - 2025-03-14

### Tests
- Add tests for `generate_job_id` uniqueness and collision handling

## [1.9.2] - 2025-03-14

### Tests
- Add more edge case tests for `cmd_clone` and `cmd_history`
- Add regression tests for `set -e` edge cases

## [1.9.1] - 2025-03-14

### Fixed
- Replace remaining `[[ condition ]] && command` patterns with if-then for safety

### Added
- Add `--quiet` flag for scripting use cases

### Tests
- Add more edge case tests for better coverage

## [1.9.0] - 2025-03-13

### Added
- Add `clone` command to duplicate jobs with optional overrides
- Add `export` and `import` commands for job backup/restore

### Tests
- Add edge case tests for validation and caching

## [1.8.3] - 2025-03-13

### Fixed
- Preserve explicit PATH capture semantics in `cmd_add`

### Refactor
- Remove unused script var and inline PATH capture
- Remove redundant meta_file reassignment in `cmd_add`

## [1.8.2] - 2025-03-13

### Documentation
- Add simplified Chinese README (`README.zh-CN.md`)

## [1.8.1] - 2025-03-13

### Fixed
- Add `safe_numeric` helper for timeout validation
- Improve `remove_file` graceful handling
- Add portable stat helper for Linux and macOS compatibility

### Refactor
- Extract helper functions to reduce code duplication

### Tests
- Add tests for `safe_numeric` helper function

## [1.8.0] - 2025-03-12

### Added
- Add `--tail` option for logs command
- Add `enable`/`disable` aliases for pause/resume
- Add `doctor` command for diagnostics
- Add `config` command for managing default settings
- Add `purge` command for cleaning old logs and orphaned files
- Add `run` and `edit` commands
- Add `show`, `history` commands and execution tracking
- Add `version`, `pause`, and `resume` commands

### Refactor
- Use `load_job_meta` helper to reduce code duplication
- Add `extract_job_id` helper to reduce code duplication
- Add `purge_old_files` helper to simplify `cmd_purge`
- Combine pause/disable and resume/enable aliases
- Add `build_cron_entry` helper to consolidate crontab entry building

### Tests
- Add more edge case tests for helper functions

## [1.7.0] - 2025-03-11

### Added
- Add bash completion for commands and job IDs
- Add directory locking and status tracking

### Performance
- Optimize cron validation functions
- Optimize file I/O and process calls

### Fixed
- Resolve ShellCheck warnings
- Make tests work with proper environment variable handling

### Development
- Add ShellCheck compliance and build tools
- Add BATS test infrastructure

## [1.6.0] - 2025-03-10

### Added
- Improve error handling and add timeout support
- Add per-job configuration options
- Add environment config and status command
- Use `bypassPermissions` as default and source bashrc

### Changed
- Use `~/.cc-cron` for data storage

### Documentation
- Add README with usage examples
- Update README with per-job configuration options
- Update README with new defaults
- Update README with new data directory location
- Update README with locking and status tracking features
- Update README with new features and development info

## [1.0.0] - 2025-03-09

### Added
- Initial release: cc-cron script for scheduling Claude Code commands as cron jobs
- Basic add, list, remove functionality
- Cron expression validation
- Job logging and status tracking
- License file (MIT)