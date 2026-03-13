# Opérations

## Manager TUI

Le manager TUI fournit une interface interactive pour les opérations courantes :

```bash
sudo computile-manager
```

Fonctionnalités :
- **Status dashboard** : vue d'ensemble (version, config, timer, dernier backup, espace disque)
- **Run backup** : lancer un backup complet ou un dry-run
- **View snapshots** : lister les snapshots restic
- **View logs** : consulter les logs de backup et le journal systemd
- **Repository health** : vérifier l'intégrité du repository restic
- **SSH connectivity** : tester la connexion SSH vers le gateway
- **Docker containers** : voir les conteneurs détectés (avec auto-discovery DB)
- **System health** : vérifier les prérequis, clés SSH, fichiers secrets, Tailscale
- **Configuration** : voir/éditer la configuration
- **Timer management** : activer, désactiver, déclencher le timer systemd
- **Update agent** : mettre à jour l'agent (git pull + install --update)

Nécessite `whiptail` (pré-installé sur Debian/Ubuntu) ou `dialog`.

---

## Mise à jour de l'agent (client VPS)

### Mettre à jour

```bash
cd /opt/computile-backup-agent && git pull && sudo bash client/install.sh --update
```

L'update :
- Vérifie que la version installée est différente de la version du repo
- Sauvegarde les scripts actuels pour rollback
- Met à jour les scripts, librairies, units systemd et logrotate
- Affiche les diffs systemd si des changements sont détectés
- Vérifie la version installée après la mise à jour
- Affiche le changelog entre les deux versions

La **configuration** (`/etc/computile-backup/`) n'est **jamais** modifiée par l'update.

### Forcer une mise à jour

```bash
sudo bash client/install.sh --update --force
```

Utile si la version est identique mais que vous voulez ré-installer les scripts (ex: après un cherry-pick).

### Rollback

```bash
sudo bash client/install.sh --rollback
```

Restaure la version précédente des scripts. Un seul niveau de rollback est conservé (la version juste avant le dernier update).

### Vérifier la version installée

```bash
computile-backup --version
```

## Mise à jour de la gateway

### Mettre à jour

```bash
cd /opt/computile-backup-agent && git pull && sudo bash gateway/setup_gateway.sh --update
```

L'update met à jour les scripts uniquement (gateway manager, user management). La configuration système (SMB, SSH, fail2ban) n'est pas touchée.

### Forcer une mise à jour

```bash
sudo bash gateway/setup_gateway.sh --update --force
```

### Rollback

```bash
sudo bash gateway/setup_gateway.sh --rollback
```

### Vérifier la version installée

```bash
cat /usr/local/lib/computile-gateway/VERSION
```

La version est aussi logguée à chaque exécution et taguée dans les snapshots restic (`agent:vX.Y.Z`).

---

## Lancer un backup manuellement

```bash
# Backup standard
sudo computile-backup

# Avec sortie détaillée
sudo computile-backup --verbose

# Simulation (aucune modification)
sudo computile-backup --dry-run --verbose

# Avec un fichier de config spécifique
sudo computile-backup --config /path/to/backup-agent.conf
```

## Lire les logs

### Log fichier

```bash
# Dernières lignes
tail -50 /var/log/computile-backup.log

# Suivre en temps réel
tail -f /var/log/computile-backup.log

# Chercher les erreurs
grep -i error /var/log/computile-backup.log
```

### Journal systemd

```bash
# Dernière exécution
journalctl -u computile-backup.service -e

# Aujourd'hui
journalctl -u computile-backup.service --since today

# Dernières 24h
journalctl -u computile-backup.service --since "24 hours ago"
```

## Vérifier les snapshots

```bash
# Variables d'env (ou utiliser les valeurs de votre config)
export RESTIC_REPOSITORY="sftp:backup-client@backup-gateway:/srv/backups/backup-client/data/vps-01"
export RESTIC_PASSWORD_FILE="/etc/computile-backup/restic-password"

# Lister tous les snapshots
restic snapshots

# Lister avec filtrage par tag
restic snapshots --tag "client:client-a"

# Dernier snapshot uniquement
restic snapshots --last

# Statistiques d'un snapshot
restic stats latest

# Détails d'un snapshot (fichiers inclus)
restic ls latest
restic ls latest /var/www
```

## Vérifier l'intégrité du repository

```bash
# Vérification rapide (structure seulement)
restic check

# Vérification complète (lecture d'un sous-ensemble de données)
restic check --read-data-subset=1%

# Vérification complète (toutes les données — lent)
restic check --read-data
```

La vérification complète est recommandée une fois par mois. Vous pouvez ajouter un cron mensuel :

```bash
# /etc/cron.d/computile-backup-check
0 4 1 * * root RESTIC_REPOSITORY="sftp:..." RESTIC_PASSWORD_FILE="/etc/computile-backup/restic-password" restic check --read-data-subset=10% >> /var/log/computile-backup-check.log 2>&1
```

## Gérer la rétention

La rétention est appliquée automatiquement à chaque backup. Pour la modifier, éditez la configuration :

```bash
RETENTION_KEEP_DAILY=7    # 7 backups quotidiens
RETENTION_KEEP_WEEKLY=4   # 4 backups hebdomadaires
RETENTION_KEEP_MONTHLY=6  # 6 backups mensuels
RETENTION_KEEP_YEARLY=2   # 2 backups annuels
```

### Appliquer manuellement une rétention

```bash
restic forget --prune \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 6 \
    --keep-yearly 2 \
    --host "vps-prod-01" \
    --group-by "host,tags"
```

### Voir ce qui serait supprimé (sans supprimer)

```bash
restic forget --dry-run \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 6 \
    --keep-yearly 2
```

## Gérer le timer systemd

```bash
# Voir le statut
systemctl status computile-backup.timer

# Voir les timers actifs
systemctl list-timers computile-backup.timer

# Activer
sudo systemctl enable --now computile-backup.timer

# Désactiver temporairement
sudo systemctl stop computile-backup.timer

# Désactiver définitivement
sudo systemctl disable computile-backup.timer

# Déclencher manuellement (via le service)
sudo systemctl start computile-backup.service
```

## Surveiller les dumps DB

```bash
# Voir les dumps récents
ls -lah /var/backups/computile/db/mysql/
ls -lah /var/backups/computile/db/postgres/
ls -lah /var/backups/computile/db/redis/

# Taille totale des dumps
du -sh /var/backups/computile/db/
```

## Vérifier la connectivité gateway

```bash
# Test SFTP
sftp backup-gateway <<< "ls"

# Test SSH (devrait être refusé car ForceCommand internal-sftp)
ssh backup-gateway

# Vérifier Tailscale
tailscale status
tailscale ping <gateway-ip>
```

## Logrotate

Les logs sont rotés automatiquement via logrotate :

- **Fréquence** : hebdomadaire
- **Rétention** : 12 rotations (≈ 3 mois)
- **Compression** : gzip (avec `delaycompress`)
- **Config** : `/etc/logrotate.d/computile-backup`

```bash
# Tester la rotation (simulation)
sudo logrotate -d /etc/logrotate.d/computile-backup

# Forcer une rotation
sudo logrotate -f /etc/logrotate.d/computile-backup
```

## Healthcheck

Si `HEALTHCHECK_URL` est configuré, l'agent envoie un ping HTTP GET à chaque exécution :

- **Succès** : ping vers `HEALTHCHECK_URL`
- **Échec** : ping vers `HEALTHCHECK_URL/fail`

Compatible avec [healthchecks.io](https://healthchecks.io), [Uptime Kuma](https://github.com/louislam/uptime-kuma), ou tout service acceptant un ping HTTP GET.

## Déverrouiller un backup bloqué

L'agent utilise un lock (`/var/run/computile-backup.lock/`) pour empêcher les exécutions simultanées. En cas de crash, le lock périmé est détecté automatiquement (vérification du PID).

Si le lock bloque malgré tout :

```bash
# Vérifier si un backup tourne réellement
cat /var/run/computile-backup.lock/pid
ps aux | grep computile-backup

# Supprimer le lock manuellement (si aucun backup n'est en cours)
sudo rm -rf /var/run/computile-backup.lock
```

## Interpréter les codes de sortie

| Code | Signification |
|------|---------------|
| 0 | Succès complet |
| 1 | Erreur fatale (config manquante, repo inaccessible, etc.) |
| Autre | Erreur spécifique (voir les logs pour le détail) |

Si le backup se termine avec des warnings mais sans erreur fatale, le code de sortie est 0 et les warnings sont listés dans le log et l'email de notification.
