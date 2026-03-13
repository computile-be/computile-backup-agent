# Configuration

## Fichier de configuration principal

Chemin : `/etc/computile-backup/backup-agent.conf`

Le fichier est un script Bash sourcé par l'agent. Toutes les variables sont des variables Bash standard.

---

## Référence des paramètres

### Identité

| Paramètre | Obligatoire | Description | Exemple |
|-----------|-------------|-------------|---------|
| `CLIENT_ID` | Oui | Identifiant du client | `"client-a"` |
| `HOST_ID` | Oui | Identifiant du VPS | `"vps-prod-01"` |
| `ENVIRONMENT` | Non | Environnement (tag restic) | `"prod"`, `"staging"` |
| `ROLE` | Non | Rôle du serveur (tag restic) | `"coolify"`, `"forge"`, `"hybrid"` |

### Restic

| Paramètre | Obligatoire | Description | Exemple |
|-----------|-------------|-------------|---------|
| `RESTIC_REPOSITORY` | Oui | URL du repository restic | `"sftp:user@host:/path"` |
| `RESTIC_PASSWORD_FILE` | Oui | Chemin du fichier mot de passe | `"/etc/computile-backup/restic-password"` |
| `RESTIC_CACHE_DIR` | Non | Répertoire de cache restic | `"/var/cache/restic"` |

### Chemins

| Paramètre | Obligatoire | Description | Exemple |
|-----------|-------------|-------------|---------|
| `BACKUP_ROOT` | Oui | Répertoire de travail local | `"/var/backups/computile"` |
| `LOG_FILE` | Oui | Fichier de log | `"/var/log/computile-backup.log"` |
| `INCLUDE_PATHS` | Non | Chemins à sauvegarder (tableau) | `(/etc /home /var/www)` |
| `EXCLUDE_FILE` | Non | Fichier d'exclusions restic | `"/etc/computile-backup/excludes.txt"` |

### Rétention

| Paramètre | Défaut | Description |
|-----------|--------|-------------|
| `RETENTION_KEEP_DAILY` | `7` | Snapshots quotidiens conservés |
| `RETENTION_KEEP_WEEKLY` | `4` | Snapshots hebdomadaires conservés |
| `RETENTION_KEEP_MONTHLY` | `6` | Snapshots mensuels conservés |
| `RETENTION_KEEP_YEARLY` | `2` | Snapshots annuels conservés |

### Docker & bases de données

| Paramètre | Défaut | Description |
|-----------|--------|-------------|
| `DOCKER_ENABLED` | `"yes"` | Active la détection Docker |
| `DOCKER_DB_AUTO_DISCOVERY` | `"yes"` | Détection auto des containers DB |
| `MYSQL_DUMP_ENABLED` | `"yes"` | Dumps MySQL/MariaDB |
| `POSTGRES_DUMP_ENABLED` | `"yes"` | Dumps PostgreSQL |
| `REDIS_SNAPSHOT_ENABLED` | `"no"` | Snapshots Redis (BGSAVE) |
| `DUMP_CLEANUP_DAYS` | `3` | Jours avant suppression des vieux dumps |

### Bases de données host (Forge, bare metal)

Pour les serveurs où MySQL/PostgreSQL est installé directement sur le host (Laravel Forge, Ploi, etc.) :

| Paramètre | Défaut | Description |
|-----------|--------|-------------|
| `HOST_DB_ENABLED` | `"no"` | Active les dumps de bases host |
| `HOST_MYSQL_USER` | `"root"` | Utilisateur MySQL host |
| `HOST_MYSQL_PASS_FILE` | — | Fichier contenant le mot de passe MySQL |
| `HOST_MYSQL_DATABASES` | — | Bases à dumper (vide = toutes sauf système) |
| `HOST_POSTGRES_USER` | `"postgres"` | Utilisateur PostgreSQL host |
| `HOST_POSTGRES_DATABASES` | — | Bases à dumper (vide = toutes sauf templates) |

### Bases de données manuelles (Docker)

| Paramètre | Description |
|-----------|-------------|
| `MANUAL_DBS` | Tableau d'entrées manuelles (voir format ci-dessous) |

Format d'une entrée : `"container_name|db_type|user|password|databases"`

- `container_name` : nom ou ID du container Docker
- `db_type` : `mysql`, `postgres`, `redis`
- `user` : utilisateur DB (vide = auto-détection)
- `password` : mot de passe (vide = auto-détection depuis env vars)
- `databases` : liste séparée par virgules (vide = toutes les bases)

### Email

| Paramètre | Défaut | Description |
|-----------|--------|-------------|
| `EMAIL_ENABLED` | `"no"` | Active les notifications email |
| `EMAIL_TO` | — | Adresse destinataire |
| `EMAIL_FROM` | `"backup@computile.be"` | Adresse expéditeur |
| `EMAIL_ON_SUCCESS` | `"no"` | Email aussi en cas de succès |
| `SMTP_HOST` | — | Serveur SMTP |
| `SMTP_PORT` | `"587"` | Port SMTP |
| `SMTP_USER` | — | Utilisateur SMTP |
| `SMTP_PASS_FILE` | — | Fichier contenant le mot de passe SMTP |

### Healthcheck

| Paramètre | Défaut | Description |
|-----------|--------|-------------|
| `HEALTHCHECK_URL` | — | URL à pinger après chaque backup (healthchecks.io, Uptime Kuma, etc.) |

Compatible avec tout service acceptant un ping HTTP GET : [healthchecks.io](https://healthchecks.io), [Uptime Kuma](https://github.com/louislam/uptime-kuma), etc. Ping `/fail` en cas d'échec.

### Performance & réseau

| Paramètre | Défaut | Description |
|-----------|--------|-------------|
| `RESTIC_UPLOAD_LIMIT_KB` | — | Limite d'upload en KB/s (vide = illimité) |
| `RESTIC_RETRY_COUNT` | `2` | Nombre de tentatives en cas d'échec SFTP |
| `DUMP_MIN_SPACE_MB` | `500` | Espace disque minimum (MB) avant les dumps DB |

### Vérification

| Paramètre | Défaut | Description |
|-----------|--------|-------------|
| `VERIFY_AFTER_BACKUP` | `"yes"` | Vérifie le snapshot après backup |
| `VERIFY_CHECK_DATA` | `"no"` | Lance `restic check --read-data-subset=1%` |

### Divers

| Paramètre | Défaut | Description |
|-----------|--------|-------------|
| `VERBOSE` | `"no"` | Mode verbeux (debug) |
| `DRY_RUN` | `"no"` | Simulation sans modification |

---

## Exemples de configuration

### VPS Coolify simple

```bash
CLIENT_ID="startup-xyz"
HOST_ID="vps-coolify-01"
ENVIRONMENT="prod"
ROLE="coolify"

RESTIC_REPOSITORY="sftp:backup-startup-xyz@backup-gateway:/srv/backups/backup-startup-xyz/data/vps-coolify-01"
RESTIC_PASSWORD_FILE="/etc/computile-backup/restic-password"

BACKUP_ROOT="/var/backups/computile"
LOG_FILE="/var/log/computile-backup.log"

INCLUDE_PATHS=(
    /etc
    /data/coolify
)

EXCLUDE_FILE="/etc/computile-backup/excludes.txt"

DOCKER_ENABLED="yes"
DOCKER_DB_AUTO_DISCOVERY="yes"
MYSQL_DUMP_ENABLED="yes"
POSTGRES_DUMP_ENABLED="yes"

EMAIL_ENABLED="yes"
EMAIL_TO="alerts@computile.be"
EMAIL_FROM="backup-startup-xyz@computile.email"
SMTP_HOST="ssl0.ovh.net"
SMTP_PORT="587"
SMTP_USER="backup-startup-xyz@computile.email"
SMTP_PASS_FILE="/etc/computile-backup/smtp-password"
```

### VPS Laravel Forge

```bash
CLIENT_ID="agency-abc"
HOST_ID="vps-forge-01"
ENVIRONMENT="prod"
ROLE="forge"

RESTIC_REPOSITORY="sftp:backup-agency-abc@backup-gateway:/srv/backups/backup-agency-abc/data/vps-forge-01"
RESTIC_PASSWORD_FILE="/etc/computile-backup/restic-password"

BACKUP_ROOT="/var/backups/computile"
LOG_FILE="/var/log/computile-backup.log"

INCLUDE_PATHS=(
    /etc
    /home
    /root
    /var/www
)

DOCKER_ENABLED="no"  # Pas de Docker sur ce serveur Forge

# Bases de données installées par Forge directement sur le host
HOST_DB_ENABLED="yes"
HOST_MYSQL_USER="root"
HOST_MYSQL_PASS_FILE="/etc/computile-backup/mysql-password"
# HOST_MYSQL_DATABASES=""  # vide = toutes les bases non-système

EMAIL_ENABLED="yes"
EMAIL_TO="alerts@computile.be"
EMAIL_FROM="backup-agency-abc@computile.email"
SMTP_HOST="ssl0.ovh.net"
SMTP_PORT="587"
SMTP_USER="backup-agency-abc@computile.email"
SMTP_PASS_FILE="/etc/computile-backup/smtp-password"
```

### VPS hybride Coolify + Forge

```bash
CLIENT_ID="bigcorp"
HOST_ID="vps-hybrid-01"
ENVIRONMENT="prod"
ROLE="hybrid"

RESTIC_REPOSITORY="sftp:backup-bigcorp@backup-gateway:/srv/backups/backup-bigcorp/data/vps-hybrid-01"
RESTIC_PASSWORD_FILE="/etc/computile-backup/restic-password"

BACKUP_ROOT="/var/backups/computile"
LOG_FILE="/var/log/computile-backup.log"

INCLUDE_PATHS=(
    /etc
    /home
    /root
    /var/www
    /data/coolify
    /opt
    /srv
)

DOCKER_ENABLED="yes"
DOCKER_DB_AUTO_DISCOVERY="yes"

# Déclarer manuellement une base PostgreSQL Forge (non Docker)
# Ce serveur a aussi un PostgreSQL local installé par Forge
# → On le sauvegarde séparément via un hook ou script externe

MANUAL_DBS=(
    "coolify-mariadb-prod|mysql|root||app_db,cms_db"
)

EMAIL_ENABLED="yes"
EMAIL_TO="alerts@computile.be"
EMAIL_FROM="backup-bigcorp@computile.email"
SMTP_HOST="ssl0.ovh.net"
SMTP_PORT="587"
SMTP_USER="backup-bigcorp@computile.email"
SMTP_PASS_FILE="/etc/computile-backup/smtp-password"
```

### VPS Docker sans Coolify

```bash
CLIENT_ID="techco"
HOST_ID="vps-docker-01"
ENVIRONMENT="prod"
ROLE="docker"

RESTIC_REPOSITORY="sftp:backup-techco@backup-gateway:/srv/backups/backup-techco/data/vps-docker-01"
RESTIC_PASSWORD_FILE="/etc/computile-backup/restic-password"

BACKUP_ROOT="/var/backups/computile"
LOG_FILE="/var/log/computile-backup.log"

INCLUDE_PATHS=(
    /etc
    /home
    /opt/apps
    /srv
)

DOCKER_ENABLED="yes"
DOCKER_DB_AUTO_DISCOVERY="yes"
REDIS_SNAPSHOT_ENABLED="yes"  # Ce client utilise Redis activement

EMAIL_ENABLED="yes"
EMAIL_TO="alerts@computile.be"
```

---

## Fichier d'exclusions

Chemin : `/etc/computile-backup/excludes.txt`

Un pattern par ligne, syntaxe restic. Voir la [documentation restic](https://restic.readthedocs.io/en/latest/040_backup.html#excluding-files).

Exemples :

```
# Cache et fichiers temporaires
/var/cache
/tmp
**/node_modules
**/.cache

# Données Docker internes (les DB sont dumpées séparément)
/var/lib/docker/overlay2
/var/lib/docker/image
```
