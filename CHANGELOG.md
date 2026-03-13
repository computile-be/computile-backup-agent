# Changelog

All notable changes to computile-backup-agent will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

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
