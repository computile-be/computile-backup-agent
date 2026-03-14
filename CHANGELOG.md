# Changelog

All notable changes to computile-backup-agent will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [1.12.0] - 2026-03-14

### Fixed
- **database.sh**: quote `$mysql_bin`/`$mysqldump_bin` in docker exec commands to prevent word splitting; handle empty `docker_env_args` array safely
- **backup-agent.sh**: validate `last_epoch` and `disk_avail_mb` are numeric before arithmetic in health check — prevents crash on unexpected systemd/df output
- **restic.sh**: check `mktemp` success in `sync_meta_to_gateway` before writing SFTP batch file
- **install.sh**: check `mktemp -d` success; use restrictive `umask 077` when creating password files to close permissions race window
- **gateway manager**: fix temp file leak in restore browser (entries_file now created once and cleaned in trap); validate SSH keys with `ssh-keygen -l` instead of regex, strip newlines to prevent authorized_keys injection

## [1.11.2] - 2026-03-14

### Changed
- **Restore browser shows file metadata**: directory listing now displays modification date and size (human-readable) for each entry, and file detail view shows path, size, date, and permissions

## [1.11.1] - 2026-03-14

### Added
- **Auto-unlock stale restic locks** in `--monitor`: opt-in `MONITOR_AUTO_UNLOCK=yes` automatically removes locks older than `MONITOR_AUTO_UNLOCK_HOURS` (default 4h) — prevents stuck locks from blocking overnight backups

## [1.11.0] - 2026-03-14

### Added
- **Per-VPS freshness alerts** in `--monitor`: stale backup detection now drills down to each VPS individually instead of per-client only — catches individual VPS failures even when other VPS on the same client are healthy
- **NTP sync check** in `--monitor`: warns if system clock is not synchronized (via `timedatectl`)
- **Security updates check** in `--monitor`: warns if security patches are available (via `apt`)
- **Restic integrity check** in `--monitor`: optional `MONITOR_RESTIC_CHECK=yes` runs `restic check --no-lock` per repo — recommended for weekly cron only (heavy operation, 120s timeout per repo)
- **`--test-notifications`** flag: sends a test ping to healthcheck URL and/or webhook to verify notification channels are working
- **Automatic monitoring cron** in `setup_gateway.sh`: installs `/etc/cron.d/computile-backup-monitor` (every 15 min) during setup — skip with `--no-cron`
- **Interactive file browser** in restore TUI: navigate directories, inspect files, restore individual files directly from the browser

### Changed
- `--monitor` now runs 9 checks (was 6): SMB, disk, SSH, fail2ban, stale backups (per-VPS), stale locks, NTP, security updates, restic integrity (opt-in)

## [1.10.0] - 2026-03-14

### Added
- **VPS health check** (`computile-backup --check`): new client-side command that checks timer status, last backup exit code/age, disk space, and SFTP repository connectivity — text output by default, `--json` for monitoring integration. Exit codes: 0=ok, 1=degraded, 2=critical
- **Restore TUI helper** in gateway manager: browse clients → VPS → snapshots, then list files, restore full snapshot or individual paths — uses `_meta` restic passwords and `--no-lock` for safe read-only access from gateway
- **`BACKUP_BASE` configurable** via `gateway.conf`: no longer hardcoded to `/srv/backups`, supports any mount point

### Changed
- **Anti-flapping for `--monitor`**: alerts are fingerprinted (MD5 of sorted alert set) and deduplicated — repeated identical alerts are suppressed, notifications only fire when the alert set changes or returns to OK

## [1.9.0] - 2026-03-14

### Added
- **Gateway monitoring with alerts** (`--monitor`): new non-interactive mode that runs all health checks and sends notifications via healthcheck URL and/or webhook — designed for cron
  - Checks: SMB mount, disk space (configurable thresholds), SSH, fail2ban, stale backups, stuck restic locks
  - Healthcheck ping (healthchecks.io, Uptime Kuma): success/fail based on overall status
  - Webhook (Slack, Discord, ntfy, custom): POST JSON with severity, alerts list, and summary
  - Exit codes: 0=ok, 1=warning, 2=critical
- **Gateway config file** (`/etc/computile-backup/gateway.conf`): configurable thresholds and notification endpoints
  - `GATEWAY_HEALTHCHECK_URL`, `GATEWAY_WEBHOOK_URL`, `GATEWAY_WEBHOOK_HEADERS`
  - `STALE_THRESHOLD_DAYS`, `DISK_WARN_PERCENT`, `DISK_CRITICAL_PERCENT`

## [1.8.4] - 2026-03-14

### Fixed
- **Config file encoding**: replaced Unicode box-drawing separators (`─`) with ASCII dashes (`-`) in config template — fixes garbled display when metadata is viewed on systems without UTF-8 support
- **Config migration compatibility**: section parser now detects both ASCII and Unicode separators, so `--update` works correctly on existing configs with either format

## [1.8.3] - 2026-03-14

### Fixed
- **Source repo discovery**: gateway manager now searches `/srv/computile-backup-agent` in addition to `/opt/computile-backup-agent` as fallback, and resolves `.source-repo` properly — fixes self-update, create-user, and remove-user when the repo is not at the default path

## [1.8.2] - 2026-03-14

### Fixed
- **Recovery metadata sync diagnostic**: `sync_meta_to_gateway` now logs SFTP errors instead of swallowing them, warns when password file is missing, and reports the number of files synced — makes it easy to diagnose why metadata might not appear on the gateway

## [1.8.1] - 2026-03-14

### Added
- **Self-update from TUI**: new "Update gateway" menu item runs `git pull` + `setup_gateway.sh --update` without leaving the manager — shows changelog, then re-execs the new version
- **Remove SSH key**: select a client, see all keys with fingerprint and comment, remove one — completes the key management workflow alongside add/view
- **SMB auto-remount**: when system health detects the backup mount is down, offers to remount it immediately instead of just displaying "NOT MOUNTED"

## [1.8.0] - 2026-03-14

### Added
- **Stale lock removal**: locks older than 1 hour are offered for deletion directly from the "Sessions & locks" view — no more manual filesystem navigation
- **Tailscale peers overview**: new menu item showing all Tailscale peers with hostname, IP, OS, online/offline status, and connection type (direct vs relayed)
- **SFTP connectivity test per client**: validates user existence, home directory, SSH keys, permissions, group membership, and chroot ownership — diagnoses setup issues without leaving the TUI
- **Client search**: search clients by partial name instead of scrolling through the full list — single match jumps directly to detail view
- **Health report export**: `--report` (text) and `--report-json` (JSON) CLI flags for non-interactive full gateway health reports — includes system health, all client statuses, alerts, and active locks. Suitable for email, monitoring integrations, or dashboards

### Changed
- Refactored client detail view into reusable `_show_client_detail_for()` function (shared between browse and search)

## [1.7.1] - 2026-03-14

### Added
- **Add SSH key** from user management menu: paste a key or read from a file, with duplicate detection and key validation
- **Refresh size cache** option in main menu to force recomputation of storage sizes
- **Stale lock detection**: lock files older than 1 hour are flagged as potentially stuck
- Auth logs now fall back to journald when `/var/log/auth.log` is not available

### Fixed
- `--version` now reads from gateway path (`/usr/local/lib/computile-gateway/VERSION`) instead of client path
- `list_clients` no longer crashes with `set -u` when no backup clients exist
- Replaced remaining `find` calls (lock detection, snapshot counting) with direct directory listing for SMB performance
- Fixed storage view subshell variable loss in sort pipe

## [1.7.0] - 2026-03-14

### Added
- **Fail2ban management** in gateway manager: view banned IPs with reverse DNS, unban a specific IP, or unban all — accessible from the main menu

## [1.6.6] - 2026-03-14

### Changed
- **Gateway manager: instant overview** — removed `du` calls from overview and client selection menus; uses `df` for total mount usage (instant) and snapshot counts for client list. Size calculation moved to dedicated "Storage breakdown" view with 1-hour caching to avoid repeated slow traversals over SMB.

## [1.6.5] - 2026-03-14

### Fixed
- Gateway manager: replaced Unicode box-drawing characters (`─`, `═`) with ASCII equivalents (`-`, `=`) for compatibility with non-UTF-8 terminals (common on LXC containers)

## [1.6.4] - 2026-03-14

### Fixed
- **Gateway manager performance on SMB mounts**: replaced expensive recursive `find` and deep `du` with `stat` on restic directory mtimes and `ls` for snapshot counting — overview loads in seconds instead of minutes on network-mounted storage

## [1.6.3] - 2026-03-14

### Fixed
- Gateway manager crash on startup: `((var++))` with `set -e` exits when variable is `0` (arithmetic evaluates to false) — added `|| true` to all increment operations
- Fixed remaining `[[ cond ]] && assignment` patterns that silently exit with `set -e` when condition is false

## [1.6.2] - 2026-03-14

### Fixed
- Gateway manager now checks all dependencies on startup and reports missing packages clearly (instead of silent exit)
- Set `TERM=linux` fallback for LXC containers where `$TERM` is unset
- Added `ncurses-bin` to gateway package list (provides `tput`, missing on minimal LXC)

## [1.6.1] - 2026-03-14

### Fixed
- Gateway manager failed to launch silently due to `set -e` + `[[ ]] && ...` pattern at top-level — conditional terminal dimension clamping caused immediate exit when conditions were false

## [1.6.0] - 2026-03-14

### Added
- **Gateway update mechanism**: `setup_gateway.sh --update` updates gateway scripts without touching system config (SMB, SSH, fail2ban)
- **Gateway rollback**: `setup_gateway.sh --rollback` reverts to the previous version
- Gateway scripts (`create_backup_user`, `remove_backup_user`) are now installed to `/usr/local/bin/` as `computile-create-backup-user` and `computile-remove-backup-user`
- Gateway version tracked in `/usr/local/lib/computile-gateway/VERSION`
- Gateway manager now finds user management scripts in `/usr/local/bin/` (installed) or repo directory (fallback)

## [1.5.1] - 2026-03-14

### Added
- **Recovery metadata sync**: after each backup, critical recovery files (restic password, config, SSH public key) are automatically uploaded to `_meta/{HOST_ID}/` on the gateway via SFTP — ensures disaster recovery is possible even if the VPS is lost
- Gateway TUI manager now displays recovery metadata per client in the detail view

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
