# Restauration

Ce document couvre les procédures de restauration depuis les backups restic.

## Prérequis

- `restic` installé sur la machine de restauration
- Accès SFTP à la gateway (clé SSH + Tailscale)
- Le **mot de passe du repository restic** (fichier `/etc/computile-backup/restic-password`)

### Variables d'environnement

Pour toutes les commandes ci-dessous :

```bash
export RESTIC_REPOSITORY="sftp:backup-client@backup-gateway:/data/vps-01"
export RESTIC_PASSWORD_FILE="/etc/computile-backup/restic-password"
```

---

## 1. Lister les snapshots disponibles

```bash
# Tous les snapshots
restic snapshots

# Filtrés par tag
restic snapshots --tag "host:vps-prod-01"

# Dernier uniquement
restic snapshots --last
```

Chaque snapshot a un identifiant court (ex: `a1b2c3d4`).

---

## 2. Explorer le contenu d'un snapshot

```bash
# Lister tout le contenu du dernier snapshot
restic ls latest

# Lister un répertoire spécifique
restic ls latest /var/www

# Lister le contenu d'un snapshot spécifique
restic ls a1b2c3d4 /etc
```

---

## 3. Restaurer des fichiers

### Restaurer un répertoire complet

```bash
# Restaurer /var/www depuis le dernier snapshot vers /tmp/restore
restic restore latest --target /tmp/restore --include /var/www
```

Les fichiers seront dans `/tmp/restore/var/www/`.

### Restaurer un fichier unique

```bash
restic restore latest --target /tmp/restore --include /etc/nginx/nginx.conf
```

### Restaurer depuis un snapshot spécifique

```bash
restic restore a1b2c3d4 --target /tmp/restore --include /home
```

### Restaurer en écrasant (sur place)

```bash
# ATTENTION : cela écrase les fichiers existants
restic restore latest --target / --include /var/www/mysite
```

### Monter un snapshot (navigation interactive)

```bash
# Monter le repository comme un système de fichiers
mkdir -p /mnt/restic
restic mount /mnt/restic

# Dans un autre terminal, naviguer :
ls /mnt/restic/snapshots/latest/var/www/
cp /mnt/restic/snapshots/latest/path/to/file /tmp/

# Démonter quand terminé
umount /mnt/restic
```

---

## 4. Restaurer un dump MySQL/MariaDB

### Localiser le dump

```bash
# Les dumps sont dans /var/backups/computile/db/mysql/ dans le snapshot
restic ls latest /var/backups/computile/db/mysql/
```

### Extraire le dump

```bash
restic restore latest --target /tmp/restore --include /var/backups/computile/db/mysql/
```

### Restaurer dans un container Docker

```bash
# Décompresser le dump
gunzip /tmp/restore/var/backups/computile/db/mysql/container_dbname_2026-03-13T02-15-00.sql.gz

# Identifier le container cible
docker ps | grep mysql

# Copier le dump dans le container
docker cp /tmp/restore/.../container_dbname_2026-03-13T02-15-00.sql <container_id>:/tmp/

# Restaurer
docker exec -i <container_id> mysql -u root -p<password> dbname < /tmp/container_dbname_2026-03-13T02-15-00.sql

# Ou directement via pipe (sans copie intermédiaire)
gunzip -c /tmp/restore/.../container_dbname_2026-03-13T02-15-00.sql.gz \
    | docker exec -i <container_id> mysql -u root -p<password> dbname
```

### Restaurer dans un MySQL/MariaDB local (hors Docker)

```bash
gunzip -c dump_file.sql.gz | mysql -u root -p dbname
```

---

## 5. Restaurer un dump PostgreSQL

### Extraire le dump

```bash
restic restore latest --target /tmp/restore --include /var/backups/computile/db/postgres/
```

### Restaurer dans un container Docker

Les dumps PostgreSQL sont au format `pg_dump -Fc` (custom format), compressés en `.gz` :

```bash
# Décompresser le wrapper gzip
gunzip /tmp/restore/.../container_dbname_2026-03-13T02-15-00.sql.gz

# Le fichier résultant est un dump au format custom pg_dump
# Copier dans le container
docker cp /tmp/restore/.../container_dbname_2026-03-13T02-15-00.sql <container_id>:/tmp/dump.fc

# Restaurer (crée la base si nécessaire)
docker exec <container_id> pg_restore -U postgres -d dbname --clean --if-exists /tmp/dump.fc

# Ou créer une nouvelle base
docker exec <container_id> createdb -U postgres dbname_restored
docker exec <container_id> pg_restore -U postgres -d dbname_restored /tmp/dump.fc
```

### Restaurer dans un PostgreSQL local

```bash
gunzip dump_file.sql.gz
pg_restore -U postgres -d dbname --clean --if-exists dump_file.sql
```

---

## 6. Restaurer un snapshot Redis

### Extraire le fichier RDB

```bash
restic restore latest --target /tmp/restore --include /var/backups/computile/db/redis/
```

### Restaurer

```bash
# Arrêter Redis dans le container
docker exec <container_id> redis-cli SHUTDOWN NOSAVE

# Copier le fichier RDB
docker cp /tmp/restore/.../container_2026-03-13T02-15-00.rdb <container_id>:/data/dump.rdb

# Redémarrer le container
docker start <container_id>
```

---

## 7. Restauration complète d'un VPS

En cas de perte totale d'un VPS :

### 7.1 Provisionner un nouveau VPS

Installer l'OS (Ubuntu 24.04 / Debian 12/13), Docker, Tailscale.

### 7.2 Installer restic

```bash
wget https://github.com/restic/restic/releases/download/v0.17.3/restic_0.17.3_linux_amd64.bz2
bunzip2 restic_0.17.3_linux_amd64.bz2
chmod +x restic_0.17.3_linux_amd64
mv restic_0.17.3_linux_amd64 /usr/local/bin/restic
```

### 7.3 Configurer l'accès à la gateway

Restaurer ou recréer la clé SSH, configurer `/root/.ssh/config`.

### 7.4 Restaurer les fichiers système

```bash
export RESTIC_REPOSITORY="sftp:backup-client@backup-gateway:/data/vps-01"
export RESTIC_PASSWORD_FILE="/path/to/restic-password"

# Restaurer /etc, /home, etc.
restic restore latest --target / --include /etc --include /home
```

### 7.5 Restaurer les applications

```bash
restic restore latest --target / --include /var/www --include /opt --include /srv
```

### 7.6 Restaurer les bases de données

Suivre les procédures de restauration DB ci-dessus pour chaque base.

### 7.7 Redémarrer les services

```bash
# Redémarrer Docker et les containers
systemctl restart docker
docker compose up -d  # pour chaque stack

# Vérifier les services
docker ps
```

---

## Points d'attention

- **Mot de passe restic** : sans lui, les données sont irrécupérables. Conservez-le en dehors du serveur sauvegardé.
- **Ordre de restauration** : fichiers d'abord, puis bases de données.
- **Permissions** : après restauration de fichiers, vérifier les permissions (`chown`, `chmod`).
- **Containers Docker** : les containers doivent être démarrés avant de restaurer les bases.
- **Configuration réseau** : les IPs et noms d'hôte peuvent différer sur un nouveau serveur.
- **Coolify** : si vous restaurez un VPS Coolify, vérifier que `/data/coolify` est complet et que les stacks Docker Compose sont cohérentes.
