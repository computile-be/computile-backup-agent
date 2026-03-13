# Changelog

All notable changes to computile-backup-agent will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [1.5.0] - 2026-03-14

### Added
- **Gateway TUI manager** (`computile-gateway-manager`): interactive terminal UI for monitoring the backup gateway
  - Client overview dashboard: all clients with sizes, snapshot counts, last activity, staleness status
  - Per-client detail view: VPS directories, storage breakdown, SSH keys
  - Active SFTP sessions and restic lock file monitoring
  - Stale backup alerting with configurable threshold (default: 2 days)
  - Storage analysis per client (sorted by size)
  - System health checks: SMB mount, SSH service, fail2ban, Tailscale
  - User management: create, remove, view SSH keys
  - Auth log viewer (backup-related entries)
  - Non-interactive `--check-alerts` mode for cron integration
- `setup_gateway.sh` now installs the gateway manager to `/usr/local/bin/computile-gateway-manager`

## [1.4.0] - 2026-03-13

### Added
- **`--status` flag**: JSON output for fleet monitoring — agent version, last backup, snapshot count/size, disk space, timer status
- **SFTP pre-flight check**: verifies repository connectivity before starting database dumps, avoiding wasted time on unreachable gateways
- **Auto-exclude DB bind mounts**: detects bind-mounted database data directories from running containers and excludes them from restic backup — raw DB files are redundant (backed up via logical dumps) and unsafe to copy without locks
- **Systemd retry on failure**: service auto-retries up to 2 times (5 min apart) on transient failures
- **Gateway `remove_backup_user.sh`**: script to cleanly remove a client's backup user, with optional `--delete-data`
- Empty snapshot detection: warns if no filesystem paths exist and only dump directory would be backed up
- Example excludes file now includes Docker volumes and database data patterns

### Fixed
- Database dump error counting: `dump_mysql`/`dump_postgres`/host variants now return 0/1 instead of raw error count — fixes undercount when `((total_errors++))` was used on multi-error returns
- **Dump cleanup moved before new dumps** (was Phase 5, now Phase 1) — old dumps are no longer re-uploaded in every backup cycle, freeing disk space before new dumps start
- Restic password file validation: now **refuses to start** if file is world-readable (was only a warning) and checks for empty files

## [1.3.0] - 2026-03-13

### Added
- Healthcheck pings now include a detailed summary in the request body — host, client, environment, agent version, duration, snapshot size/count on success, error details on failure
- Compatible with healthchecks.io, Uptime Kuma, and any service that accepts POST body data

## [1.2.3] - 2026-03-13

### Fixed
- `install.sh --update` now reports which specific step failed instead of dying silently — non-critical steps (systemd, config migration, logrotate, restic) continue on failure with error details

## [1.2.2] - 2026-03-13

### Fixed
- SSH connectivity test in TUI manager now uses SFTP instead of SSH shell commands — the gateway uses `ForceCommand internal-sftp` which blocks regular SSH, causing the test to hang

## [1.2.1] - 2026-03-13

### Fixed
- Config migration now detects commented-out parameters from example config (e.g. `HEALTHCHECK_URL`, `RESTIC_UPLOAD_LIMIT_KB`, `RESTIC_CACHE_DIR`) — previously only active (uncommented) parameters were detected as new
- Config migration now adds **complete sections** with headers and descriptive comments instead of dumping bare variable lines — matches the structure of the example config file

## [1.2.0] - 2026-03-13

### Added
- **TUI manager** (`computile-manager`): interactive terminal UI for daily operations
  - Status dashboard (version, config, timer, last backup, disk usage)
  - Run backup (full or dry-run) directly from the menu
  - View restic snapshots, backup logs, and systemd journal
  - Repository health check (restic check + stats)
  - SSH connectivity test to backup gateway
  - Docker container discovery overview
  - System health check (prerequisites, SSH keys, secrets, Tailscale)
  - View/edit configuration with secret masking
  - Timer management (enable, disable, trigger)
  - One-click agent update (git pull + install --update)
- Config migration during updates: detects new parameters from example config, prompts interactively or appends commented out
- Shell scripts marked as executable in git

### Changed
- `install.sh` now installs `computile-manager` alongside `computile-backup`
- Rollback includes the TUI manager

## [1.1.0] - 2026-03-13

### Added
- Update mechanism: `install.sh --update` for safe in-place updates
- Rollback support: `install.sh --rollback` to revert to previous version
- `VERSION` file as single source of truth for agent version
- Agent version tag (`agent:vX.Y.Z`) in restic snapshots for fleet tracking
- Source repo path saved to `/usr/local/lib/computile-backup/.source-repo`
- Systemd diff display during updates (shows changes before applying)
- Changelog display during updates (shows what changed since installed version)

### Changed
- Agent version is now read from `VERSION` file instead of hardcoded constant
- Install banner now shows version number
- Install completion message includes update command hint

## [1.0.0] - 2026-03-13

### Added
- Initial release
- Restic backup with SFTP transport over Tailscale
- Docker container auto-discovery for MySQL/MariaDB, PostgreSQL, Redis
- Host-level database dumps (Forge, bare metal)
- MariaDB 11+ client binary detection
- Interactive installer with guided configuration wizard
- Configurable retention policy (daily/weekly/monthly/yearly)
- Email notifications via msmtp
- Healthcheck ping support (healthchecks.io, Uptime Kuma)
- Retry with exponential backoff for transient SFTP failures
- Disk space pre-checks before database dumps
- Snapshot stats reporting
- Logrotate configuration
- Systemd service and timer with security hardening
- SSH key generation and config in installer
- Atomic config file generation
- Filename sanitization for database dumps
- Gateway setup script with per-client SFTP isolation
