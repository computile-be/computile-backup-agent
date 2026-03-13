# Troubleshooting

## Restic repository inaccessible

### Symptôme
```
Restic repository is not accessible or not initialized
```

### Diagnostic

```bash
# Tester la connectivité SFTP
sftp backup-gateway

# Tester Tailscale
tailscale ping <gateway-ip>

# Tester manuellement restic
export RESTIC_REPOSITORY="sftp:backup-client@backup-gateway:/data/vps-01"
export RESTIC_PASSWORD_FILE="/etc/computile-backup/restic-password"
restic snapshots
```

### Causes fréquentes

1. **Tailscale déconnecté** → `sudo tailscale up`
2. **Clé SSH manquante ou permissions incorrectes** → `chmod 600 /root/.ssh/backup_ed25519`
3. **Config SSH manquante** → Vérifier `/root/.ssh/config`
4. **Gateway éteinte ou service SSH arrêté** → Vérifier côté gateway
5. **Repository non initialisé** → `sudo computile-backup --init`
6. **Mauvais mot de passe restic** → Vérifier `/etc/computile-backup/restic-password`

---

## Problème de clé SSH

### Symptôme
```
Permission denied (publickey)
```

### Diagnostic

```bash
# Tester avec verbose
ssh -vv backup-gateway

# Vérifier que la clé existe
ls -la /root/.ssh/backup_ed25519*

# Vérifier la config SSH
cat /root/.ssh/config
```

### Résolution

```bash
# Régénérer une clé si nécessaire
ssh-keygen -t ed25519 -f /root/.ssh/backup_ed25519 -N ""

# Copier la clé publique sur la gateway
cat /root/.ssh/backup_ed25519.pub
# → Ajouter au fichier authorized_keys du user backup sur la gateway
```

**Sur la gateway** :
```bash
# Vérifier les permissions (critique pour le chroot SFTP)
ls -la /srv/backups/client-id/
# Le répertoire chroot doit appartenir à root:root

ls -la /srv/backups/client-id/.ssh/
# .ssh/ doit appartenir au user backup
# authorized_keys doit être en 600
```

---

## Erreur SMB côté gateway

### Symptôme
Le montage `/srv/backups` n'est pas disponible.

### Diagnostic

```bash
# Vérifier le montage
df -h /srv/backups
mount | grep srv/backups

# Tenter un remontage
sudo mount /srv/backups

# Vérifier les credentials
cat /root/.smb-credentials

# Tester manuellement
sudo mount -t cifs //synology-ip/backups /srv/backups \
    -o credentials=/root/.smb-credentials,vers=3.0
```

### Causes fréquentes

1. **Synology éteint ou en maintenance** → Vérifier l'état du NAS
2. **Credentials invalides** → Vérifier `/root/.smb-credentials`
3. **Réseau** → Vérifier la connectivité entre gateway et Synology
4. **Version SMB** → Ajouter `vers=3.0` dans fstab
5. **Paquet manquant** → `apt install cifs-utils`

---

## Container DB non détecté

### Symptôme
```
No database containers discovered
```

### Diagnostic

```bash
# Vérifier les containers en cours
docker ps

# Vérifier les images
docker ps --format '{{.Names}}\t{{.Image}}'

# Tester la détection manuellement (images contenant mysql, mariadb, postgres, redis)
docker ps --format '{{.Names}}\t{{.Image}}' | grep -iE 'mysql|mariadb|postgres|redis'
```

### Causes fréquentes

1. **Container arrêté** → `docker start <container>`
2. **Image avec nom non standard** → Utiliser `MANUAL_DBS` dans la config
3. **Docker pas accessible** → Vérifier que root peut exécuter `docker ps`
4. **DOCKER_ENABLED="no"** → Vérifier la config

### Utiliser le mode manuel

Si l'auto-détection ne fonctionne pas, déclarer les containers manuellement :

```bash
# Dans backup-agent.conf
MANUAL_DBS=(
    "mon-container-mariadb|mysql|root|monpassword|mabase"
)
```

---

## Dump DB échoué

### Symptôme
```
Failed to dump database: mydb from container-name
```

### Diagnostic

```bash
# Tester le dump manuellement
docker exec <container> mysqldump -u root -p<password> --single-transaction mydb > /tmp/test.sql

# Pour PostgreSQL
docker exec <container> pg_dump -U postgres mydb > /tmp/test.sql

# Vérifier les variables d'environnement du container
docker inspect <container> --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -iE 'password|user|db'
```

### Causes fréquentes

1. **Mauvais mot de passe** → Vérifier les env vars du container (`MYSQL_ROOT_PASSWORD`, etc.)
2. **Base inexistante** → Vérifier le nom de la base
3. **Container sans client dump** → L'image doit contenir `mysqldump` ou `pg_dump`
4. **Permissions** → L'utilisateur doit avoir les droits de lecture sur la base
5. **Base verrouillée** → Vérifier s'il y a un processus de migration en cours

### Astuce : tester les credentials

```bash
# MySQL/MariaDB
docker exec <container> mysql -u root -p<password> -e "SHOW DATABASES;"

# PostgreSQL
docker exec <container> psql -U postgres -l
```

---

## Email non envoyé

### Symptôme
```
Failed to send email notification
```

### Diagnostic

```bash
# Tester msmtp directement
echo "Test" | msmtp --debug alerts@computile.be

# Vérifier la config msmtp
cat /etc/computile-backup/msmtprc

# Vérifier le log msmtp
cat /var/log/msmtp.log

# Vérifier que msmtp est installé
which msmtp
```

### Causes fréquentes

1. **msmtp non installé** → `apt install msmtp msmtp-mta`
2. **Config manquante** → Vérifier `/etc/computile-backup/msmtprc`
3. **Mauvais identifiants SMTP** → Vérifier user/password OVH
4. **Port bloqué** → Certains hébergeurs bloquent le port 587, tester avec 465
5. **Certificat TLS** → `apt install ca-certificates`

### Tester avec une config minimale

```bash
cat > /tmp/test-msmtp.conf <<EOF
account default
host ssl0.ovh.net
port 587
auth on
user backup@computile.email
password VOTREPASSWORD
from backup@computile.email
tls on
tls_starttls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
EOF

echo -e "Subject: Test\n\nTest backup notification" | msmtp -C /tmp/test-msmtp.conf alerts@computile.be
rm /tmp/test-msmtp.conf
```

---

## Backup trop lent

### Diagnostic

```bash
# Vérifier la bande passante vers la gateway
# (installer iperf3 sur les deux machines)
iperf3 -c <gateway-ip>

# Vérifier la taille des données
du -sh /etc /home /var/www /data/coolify

# Vérifier la taille du repository
restic stats
```

### Solutions

1. **Exclusions** : ajouter des patterns dans `excludes.txt` (node_modules, .cache, logs)
2. **Cache restic** : activer `RESTIC_CACHE_DIR="/var/cache/restic"` pour accélérer les backups suivants
3. **Bande passante** : si le réseau Tailscale est lent, vérifier la route (relayed vs direct)
   ```bash
   tailscale ping <gateway-ip>
   # Si "via DERP", la connexion est relayée — c'est plus lent
   ```

---

## Lockfile bloqué

### Symptôme
```
Another backup is already running (PID 12345)
```

### Diagnostic

```bash
# Vérifier si le processus existe vraiment
ps aux | grep 12345

# Vérifier le lockfile
cat /var/run/computile-backup.lock
```

### Résolution

Si le processus n'existe plus (crash précédent) :

```bash
sudo rm /var/run/computile-backup.lock
```

Si un backup est réellement en cours, attendre sa fin ou l'arrêter proprement.

---

## Espace disque insuffisant

### Symptôme

Erreur lors des dumps ou du backup restic.

### Diagnostic

```bash
df -h
du -sh /var/backups/computile/db/
```

### Solutions

1. **Nettoyer les vieux dumps** : `find /var/backups/computile/db -mtime +3 -delete`
2. **Réduire DUMP_CLEANUP_DAYS** dans la config
3. **Exclure des chemins** volumineux non critiques
4. **Augmenter le disque** du VPS
