# computile-backup-agent

Multi-client backup agent for Linux VPS servers. Uses **restic** for incremental, encrypted backups sent via SFTP to a centralized gateway backed by a Synology NAS.

## Features

### Backup engine
- Incremental, deduplicated, encrypted backups with restic
- SFTP transport over Tailscale to a centralized gateway
- Configurable retention policy (daily / weekly / monthly / yearly)
- Post-backup verification with optional deep data checks
- Bandwidth throttling (`RESTIC_UPLOAD_LIMIT_KB`)
- Retry with exponential backoff for transient SFTP failures
- Disk space pre-checks before database dumps
- Dry-run mode for testing without changes

### Database discovery & dumps
- Auto-discovery of Docker containers running MySQL/MariaDB, PostgreSQL, or Redis
- Logical dumps via `docker exec` (not raw volume copies)
- Host-level database dumps for non-Docker setups (Laravel Forge, bare metal)
- MariaDB 11+ client binary detection (`mariadb-dump`)
- Per-type toggles and manual database entries for fine-grained control
- Credentials auto-detection from Docker environment variables

### Monitoring & notifications
- **Healthcheck pings** (healthchecks.io, Uptime Kuma) with detailed summary: host, client, env, agent version, duration, snapshot size/count, errors
- **Email notifications** on failure (and optionally on success) via msmtp
- Snapshot statistics and repository health checks
- Structured logging with logrotate integration

### TUI manager (`computile-manager`)
- Status dashboard (version, config, timer, last backup, disk usage)
- Run backup (full or dry-run) directly from the menu
- View restic snapshots, backup logs, and systemd journal
- Repository health check (restic check + stats)
- SSH/SFTP connectivity test to backup gateway
- Docker container discovery overview
- System health check (prerequisites, SSH keys, secrets, Tailscale)
- Configuration viewer with secret masking
- Timer management (enable, disable, trigger)
- One-click agent update

### Installation & updates
- Interactive installer with guided configuration wizard
- Non-interactive mode for scripted deployments (`--non-interactive`)
- Safe in-place updates with `install.sh --update`
- Config migration: detects new parameters and adds them with section headers
- One-level rollback (`install.sh --rollback`)
- Agent version tag in every restic snapshot for fleet tracking

### Gateway
- Per-client SFTP-only users with chroot isolation
- SSH hardening (no shell, no tunneling, `ForceCommand internal-sftp`)
- Fail2ban integration
- Automated SMB mount to Synology NAS
- Per-VPS subdirectories within client storage

### Security
- Passwords stored in separate files with permission validation
- Secret masking in TUI and logs
- Atomic config file generation
- Systemd service hardening (idle CPU/IO scheduling, 6h timeout)
- Lock file to prevent concurrent runs

## Architecture

```
[VPS client]  →  restic via SFTP/SSH  →  [Gateway VM]  →  SMB  →  [Synology NAS]
                   (Tailscale)              (Linux)                 (RackStation)
```

## Quick start

### Gateway setup

```bash
git clone https://github.com/computile-be/computile-backup-agent.git /opt/computile-backup-agent
cd /opt/computile-backup-agent/gateway
sudo bash setup_gateway.sh
sudo computile-create-backup-user <client-id> --vps <vps-id>
```

### VPS client setup

```bash
git clone https://github.com/computile-be/computile-backup-agent.git /opt/computile-backup-agent
cd /opt/computile-backup-agent/client
sudo bash install.sh
sudo computile-backup --init --verbose
sudo systemctl enable --now computile-backup.timer

# Launch TUI manager
sudo computile-manager
```

### Updating an existing installation

**Client (VPS):**
```bash
cd /opt/computile-backup-agent && git pull && sudo bash client/install.sh --update
```

Rollback if needed: `sudo bash client/install.sh --rollback`

**Gateway:**
```bash
cd /opt/computile-backup-agent && git pull && sudo bash gateway/setup_gateway.sh --update
```

Rollback if needed: `sudo bash gateway/setup_gateway.sh --rollback`

### Command-line usage

```
computile-backup [--config FILE] [--init] [--dry-run] [--verbose] [--version] [--help]
```

## Configuration

All settings are in `/etc/computile-backup/backup-agent.conf`. See the [example config](client/backup-agent.conf.example) for all available options with descriptions.

Key files:
| Path | Purpose |
|------|---------|
| `/etc/computile-backup/backup-agent.conf` | Main configuration |
| `/etc/computile-backup/restic-password` | Restic encryption password |
| `/etc/computile-backup/smtp-password` | SMTP credentials (optional) |
| `/etc/computile-backup/excludes.txt` | Restic exclusion patterns |
| `/etc/computile-backup/ssh/id_ed25519` | SSH key for gateway |

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Deployment](docs/DEPLOYMENT.md)
- [Configuration](docs/CONFIGURATION.md)
- [Operations](docs/OPERATIONS.md)
- [Restore](docs/RESTORE.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)

## Requirements

- Ubuntu 24.04 or Debian 12/13
- Tailscale
- Docker (if backing up containerized databases)
- Synology NAS with SMB share (gateway side)
- restic, jq, curl (installed automatically)

## License

MIT
