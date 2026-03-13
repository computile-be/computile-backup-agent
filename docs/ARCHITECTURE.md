# Architecture

## Vue d'ensemble

```
┌──────────────────┐     SFTP/SSH      ┌───────────────────┐     SMB/CIFS     ┌──────────────────┐
│   VPS Client     │ ──────────────────→│  VM Gateway       │ ───────────────→ │  Synology NAS    │
│                  │    (Tailscale)     │  (Linux)          │                  │  (RackStation)   │
│  backup-agent    │                   │                   │                  │                  │
│  + restic        │                   │  /srv/backups/    │                  │  /backups/       │
│  + docker exec   │                   │  (mount SMB)      │                  │                  │
└──────────────────┘                   └───────────────────┘                  └──────────────────┘
```

## Pourquoi cette architecture ?

### Restic comme moteur de backup

- **Déduplication** : seules les données modifiées sont envoyées
- **Chiffrement** : les données sont chiffrées côté client avant envoi
- **Snapshots versionnés** : chaque backup est un snapshot immutable
- **SFTP natif** : transport sécurisé sans composant serveur spécifique
- **Rétention flexible** : politique configurable (daily/weekly/monthly)

### Gateway intermédiaire (et non Synology direct)

- **Sécurité** : le NAS n'est jamais exposé directement en SSH/SFTP
- **Isolation** : chaque client a un utilisateur SFTP chrooted
- **Flexibilité** : la gateway peut être remplacée sans toucher au NAS
- **Hardening** : fail2ban, SSH restreint, pas de shell interactif
- **Audit** : logs centralisés sur la gateway

### Dumps logiques pour les bases Docker

Les fichiers bruts d'une base de données en cours d'exécution (volumes Docker) ne sont **pas** une sauvegarde fiable. Ils peuvent être incohérents ou corrompus.

Le backup agent effectue des **dumps logiques** via `docker exec` :

- **MySQL/MariaDB** : `mysqldump --single-transaction` (cohérent, sans verrouillage)
- **PostgreSQL** : `pg_dump -Fc` (format custom, compressé)
- **Redis** : `BGSAVE` + copie du `dump.rdb` (optionnel)

Les dumps sont stockés localement puis inclus dans le snapshot restic.

## Flux de données

```
1. Chargement de la configuration
2. Acquisition du lock (un seul backup à la fois)
3. Vérification des prérequis (restic, docker, msmtp)
4. ── Phase 1 : Dumps de bases de données ──
   a. Détection auto des containers DB (image, labels)
   b. Extraction des credentials (env vars du container)
   c. Exécution des dumps via docker exec
   d. Compression des dumps (.sql.gz)
5. ── Phase 2 : Backup restic ──
   a. Inclusion des chemins configurés (/etc, /home, /var/www, ...)
   b. Inclusion du répertoire des dumps DB
   c. Envoi incrémental vers la gateway via SFTP
6. ── Phase 3 : Rétention ──
   a. restic forget --prune selon la politique configurée
7. ── Phase 4 : Vérification ──
   a. Vérification du dernier snapshot
   b. Optionnel : restic check --read-data-subset
8. ── Phase 5 : Nettoyage ──
   a. Suppression des vieux dumps locaux
9. Notification email (succès ou échec)
10. Libération du lock
```

## Structure des fichiers

### Sur le VPS client

```
/etc/computile-backup/
  backup-agent.conf       # Configuration principale
  excludes.txt            # Patterns d'exclusion restic
  restic-password         # Mot de passe du repo restic (600)
  smtp-password           # Mot de passe SMTP (600)
  msmtprc                 # Config msmtp générée (600)

/usr/local/bin/
  computile-backup        # Script principal

/usr/local/lib/computile-backup/
  common.sh               # Fonctions utilitaires
  docker.sh               # Détection Docker
  database.sh             # Dumps de bases
  notify.sh               # Notifications email
  restic.sh               # Opérations restic

/var/backups/computile/
  db/
    mysql/                # Dumps MySQL/MariaDB
    postgres/             # Dumps PostgreSQL
    redis/                # Snapshots Redis

/var/log/
  computile-backup.log    # Log principal
```

### Sur la gateway

```
/srv/backups/
  backup-<client-id>/           # Répertoire chroot (= username SSH)
    data/
      <vps-id>/                 # Repository restic du VPS
    .ssh/
      authorized_keys           # Clés SSH autorisées
```

## Sécurité

- **Chiffrement restic** : toutes les données sont chiffrées avec le mot de passe du repository
- **Transport SSH** : chiffrement en transit via SFTP
- **Réseau Tailscale** : communication VPS ↔ gateway sur réseau privé
- **Isolation SFTP** : chaque client est chrooted, pas de shell
- **Clés SSH** : authentification par clé uniquement (pas de mot de passe)
- **Permissions** : fichiers de config et secrets en 600, répertoires en 700
- **fail2ban** : protection contre le brute-force SSH
- **Pas de secrets en dur** : tous les mots de passe dans des fichiers séparés
