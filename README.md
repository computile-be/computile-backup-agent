# computile-backup-agent

Multi-client backup agent for Linux VPS servers. Uses **restic** for incremental, encrypted backups sent via SFTP to a centralized gateway backed by a Synology NAS.

## Features

- Incremental, deduplicated, encrypted backups with restic
- Auto-discovery of Docker database containers (MySQL/MariaDB, PostgreSQL, Redis)
- Logical dumps via `docker exec` (not raw volume copies)
- Configurable retention policy (daily/weekly/monthly/yearly)
- Email notifications on failure (via msmtp + OVH SMTP)
- Systemd timer for automated daily backups
- Works with Coolify, Laravel Forge, hybrid, or bare Linux servers
- SFTP gateway with per-client isolation over Tailscale
- Interactive TUI manager (`computile-manager`) for daily operations

## Architecture

```
[VPS client]  →  restic via SFTP/SSH  →  [Gateway VM]  →  SMB  →  [Synology NAS]
                   (Tailscale)              (Linux)                 (RackStation)
```

## Quick start

### Gateway setup

```bash
git clone https://github.com/computile-be/computile-backup-agent.git
cd computile-backup-agent/gateway
sudo bash setup_gateway.sh
sudo bash create_backup_user.sh <client-id> --vps <vps-id>
```

### VPS client setup

```bash
git clone https://github.com/computile/computile-backup-agent.git /opt/computile-backup-agent
cd /opt/computile-backup-agent/client
sudo bash install.sh
sudo computile-backup --init --verbose
sudo systemctl enable --now computile-backup.timer

# Launch TUI manager
sudo computile-manager
```

### Updating an existing installation

```bash
cd /opt/computile-backup-agent && git pull && sudo bash client/install.sh --update
```

Rollback if needed: `sudo bash client/install.sh --rollback`

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
- Synology NAS with SMB share

## License

MIT
