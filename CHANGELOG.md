# Changelog

All notable changes to computile-backup-agent will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

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
