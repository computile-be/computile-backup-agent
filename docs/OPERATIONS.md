# Opérations

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
restic check --read-data-subset=5%

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
```

### Appliquer manuellement une rétention

```bash
restic forget --prune \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 6 \
    --tag "host:vps-prod-01" \
    --group-by "host,tags"
```

### Voir ce qui serait supprimé (sans supprimer)

```bash
restic forget --dry-run \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 6
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

## Interpréter les codes de sortie

| Code | Signification |
|------|---------------|
| 0 | Succès complet |
| 1 | Erreur fatale (config manquante, repo inaccessible, etc.) |
| Autre | Erreur spécifique (voir les logs pour le détail) |

Si le backup se termine avec des warnings mais sans erreur fatale, le code de sortie est 0 et les warnings sont listés dans le log et l'email de notification.
