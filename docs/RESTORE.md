# Restauration

Ce document couvre les procédures de restauration depuis les backups restic.

## Prérequis

- `restic` installé sur la machine de restauration
- Accès SFTP à la gateway (clé SSH + Tailscale)
- Le **mot de passe du repository restic** (fichier `/etc/computile-backup/restic-password`)

### Variables d'environnement

Pour toutes les commandes ci-dessous :

```bash
export RESTIC_REPOSITORY="sftp:backup-client@backup-gateway:/srv/backups/backup-client/data/vps-01"
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

Les dumps PostgreSQL sont au format SQL plain text, compressés en `.sql.gz` :

```bash
# Directement via pipe (sans copie intermédiaire)
gunzip -c /tmp/restore/.../container_dbname_2026-03-13T02-15-00.sql.gz \
    | docker exec -i <container_id> psql -U postgres -d dbname

# Ou créer une nouvelle base avant restauration
docker exec <container_id> createdb -U postgres dbname_restored
gunzip -c /tmp/restore/.../container_dbname_2026-03-13T02-15-00.sql.gz \
    | docker exec -i <container_id> psql -U postgres -d dbname_restored
```

### Restaurer dans un PostgreSQL local

```bash
gunzip -c dump_file.sql.gz | psql -U postgres -d dbname
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
export RESTIC_REPOSITORY="sftp:backup-client@backup-gateway:/srv/backups/backup-client/data/vps-01"
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

## 8. Restauration d'un VPS Coolify

Coolify stocke sa configuration, ses clés SSH et sa base de données dans `/data/coolify`. Cette procédure suit les recommandations officielles de Coolify.

> **Référence** : https://coolify.io/docs/knowledge-base/how-to/backup-restore-coolify

### Fichiers critiques sauvegardés

| Fichier | Rôle |
|---------|------|
| `/data/coolify/source/.env` | Contient l'`APP_KEY` (clé de chiffrement Coolify) |
| `/data/coolify/ssh/keys/` | Clés SSH ED25519 pour la connexion aux serveurs |
| Base `coolify` dans `coolify-db` | Configuration Coolify, projets, variables d'environnement |

### 8.1 Installer Coolify sur le nouveau serveur

Installer Coolify **à la même version** que le serveur original :

```bash
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
```

### 8.2 Noter l'APP_KEY du nouveau serveur

```bash
# Sauvegarder la nouvelle APP_KEY (on en aura besoin)
grep APP_KEY /data/coolify/source/.env
```

### 8.3 Restaurer les fichiers depuis restic

```bash
export RESTIC_REPOSITORY="sftp:backup-client@backup-gateway:/srv/backups/backup-client/data/vps-01"
export RESTIC_PASSWORD_FILE="/path/to/restic-password"

# Extraire /data/coolify dans un répertoire temporaire
restic restore latest --target /tmp/restore --include /data/coolify
```

### 8.4 Arrêter Coolify

```bash
docker stop coolify coolify-redis coolify-realtime coolify-proxy
```

### 8.5 Restaurer la base de données Coolify

```bash
# Extraire le dump PostgreSQL de coolify-db
restic restore latest --target /tmp/restore --include /var/backups/computile/db/postgres/

# Trouver le dump coolify-db
ls /tmp/restore/var/backups/computile/db/postgres/coolify-db_coolify_*

# Restaurer dans le container coolify-db
gunzip -c /tmp/restore/var/backups/computile/db/postgres/coolify-db_coolify_*.sql.gz \
    | docker exec -i coolify-db psql -U coolify -d coolify
```

### 8.6 Restaurer les clés SSH

```bash
# Supprimer les clés auto-générées
rm -f /data/coolify/ssh/keys/*

# Restaurer les clés depuis le backup
cp /tmp/restore/data/coolify/ssh/keys/* /data/coolify/ssh/keys/

# Corriger les permissions
chown -R root:root /data/coolify/ssh/keys/
chmod 600 /data/coolify/ssh/keys/*
```

### 8.7 Configurer APP_PREVIOUS_KEYS

L'`APP_KEY` a changé entre l'ancien et le nouveau serveur. Coolify doit connaître l'ancienne clé pour déchiffrer les secrets stockés en base :

```bash
# Récupérer l'ancienne APP_KEY depuis le backup
OLD_KEY=$(grep APP_KEY /tmp/restore/data/coolify/source/.env | cut -d= -f2)

# Ajouter au .env du nouveau serveur
echo "APP_PREVIOUS_KEYS=${OLD_KEY}" >> /data/coolify/source/.env
```

> **Si vous avez migré plusieurs fois**, séparer les clés par des virgules sans espaces : `APP_PREVIOUS_KEYS=key1,key2,key3`

### 8.8 Redémarrer Coolify

```bash
# Relancer via le script officiel (redémarre tous les containers)
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
```

### 8.9 Vérifier

- Se connecter au dashboard Coolify avec les anciens identifiants
- Vérifier la connectivité SSH aux serveurs dans Settings > Servers
- Si erreur 500 au login : vérifier `APP_PREVIOUS_KEYS` dans `/data/coolify/source/.env`
- Si erreur SSH "permission denied" : vérifier que les clés dans `/data/coolify/ssh/keys/` correspondent à celles de l'ancien serveur

> **Note** : cette procédure restaure l'instance Coolify elle-même. Les données des applications (volumes Docker) sont restaurées séparément via les fichiers (`/data/coolify`, `/opt`, `/srv`) et les dumps de bases de données.

---

## 9. Test automatisé de restore

L'outil `computile-restore-test` permet de valider qu'un backup est fonctionnel en orchestrant un restore complet sur un VM vierge.

### Prérequis

- Un VM vierge accessible via Tailscale (Ubuntu/Debian)
- `restic` et `rsync` installés sur la gateway
- Un utilisateur SSH sur la cible avec accès sudo (par défaut : `computile-restore`)

### Préparation du VM cible

L'outil utilise par défaut l'utilisateur `computile-restore` sur la cible. Cet utilisateur doit être pré-créé avant le test :

```bash
# Sur le VM cible
sudo useradd -r -m -s /bin/bash computile-restore
printf '%s\n%s\n' 'computile-restore ALL=(ALL) NOPASSWD: ALL' 'Defaults:computile-restore !use_pty' | sudo tee /etc/sudoers.d/computile-restore
sudo chmod 440 /etc/sudoers.d/computile-restore

# Copier la clé SSH de la gateway
sudo mkdir -p /home/computile-restore/.ssh
sudo cp ~/.ssh/authorized_keys /home/computile-restore/.ssh/  # ou ajouter la clé de la gateway
sudo chown -R computile-restore:computile-restore /home/computile-restore
```

> **Note** : le rsync n'utilise pas `--delete`, donc le dossier `/home/computile-restore` (absent du backup) n'est pas touché. L'outil sauvegarde l'identité SSH du user avant le restore et la ré-injecte automatiquement après chaque rsync via un script fixup.

### Usage interactif (TUI)

```bash
# Depuis le menu gateway manager
sudo computile-gateway-manager
# → "Test restore on a fresh VM"

# Ou directement
sudo computile-restore-test --interactive
```

### Usage CLI (non-interactif)

```bash
# Avec l'utilisateur computile-restore pré-créé (défaut)
sudo computile-restore-test \
    --client mycompany \
    --vps vps-prod-01 \
    --target test-vm.tail1234.ts.net

# Avec un autre utilisateur SSH spécifique
sudo computile-restore-test \
    --client mycompany \
    --vps vps-prod-01 \
    --target test-vm.tail1234.ts.net \
    --ssh-user other-user
```

### Options

| Option | Description |
|--------|-------------|
| `--client CLIENT` | Nom du client (sans préfixe `backup-`) |
| `--vps VPS` | Hostname/ID du VPS |
| `--target HOST` | Hostname/IP Tailscale du VM cible |
| `--snapshot ID` | Snapshot spécifique (défaut : `latest`) |
| `--interactive` | Mode TUI avec sélection guidée |
| `--ssh-user USER` | User SSH sur la cible (défaut : `computile-restore`) |
| `--ssh-port PORT` | Port SSH (défaut : `22`) |
| `--skip-db-restore` | Ignorer la restauration des bases de données |
| `--skip-cleanup` | Conserver les fichiers temporaires |
| `--report-dir DIR` | Répertoire de sortie du rapport |
| `--dry-run` | Affiche les étapes sans exécuter |

### Gestion de la connexion SSH pendant le restore

Le restore écrase des fichiers système critiques (`/etc/passwd`, `/etc/shadow`, `/etc/ssh/`, `/home/`) qui peuvent casser la connexion SSH. L'outil gère cela de deux façons :

1. **Utilisateur dédié** : `computile-restore` a son home dans `/tmp` (jamais touché par le restore). Ainsi, le rsync de `/home` ne casse pas la connexion.

2. **Fixup automatique** : un script wrapper rsync s'exécute sur la cible après chaque rsync. Il ré-injecte l'utilisateur `computile-restore` dans `/etc/passwd`, restaure les clés SSH host et redémarre sshd — le tout dans la **même session SSH** que rsync. La connexion n'est jamais perdue.

### Phases d'exécution

1. **Pre-flight** : connectivité SSH, OS cible, espace disque, mémoire, snapshot restic
2. **File restore** : extraction locale du snapshot + rsync vers la cible (ou streaming direct)
3. **Platform** : installation Coolify, restauration SSH keys, APP_PREVIOUS_KEYS
4. **Databases** : import des dumps MySQL, PostgreSQL, Redis
5. **Verification** : Docker, containers, dashboard Coolify, connexions DB, apps HTTP
6. **Cleanup** : suppression des fichiers temporaires

### Rapport

Un rapport détaillé est généré dans `/var/log/computile-backup/restore-test-{client}-{vps}-{date}.log` avec le statut de chaque vérification (OK/KO/WARN/SKIP).

---

## Points d'attention

- **Mot de passe restic** : sans lui, les données sont irrécupérables. Conservez-le en dehors du serveur sauvegardé.
- **Ordre de restauration** : fichiers d'abord, puis bases de données.
- **Permissions** : après restauration de fichiers, vérifier les permissions (`chown`, `chmod`).
- **Containers Docker** : les containers doivent être démarrés avant de restaurer les bases.
- **Configuration réseau** : les IPs et noms d'hôte peuvent différer sur un nouveau serveur.
