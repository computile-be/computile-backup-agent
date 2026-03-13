# Déploiement

## Prérequis

### Réseau

- **Tailscale** installé et connecté sur le VPS et la gateway
- Le VPS peut atteindre la gateway via son IP Tailscale
- Port SSH (22) ouvert entre VPS et gateway sur le réseau Tailscale

### Gateway VM

- Ubuntu 24.04 ou Debian 12/13
- Accès réseau au Synology (SMB/CIFS)
- Tailscale installé
- Au moins 1 Go de RAM, 10 Go de disque local (les données vont sur le NAS)

### VPS client

- Ubuntu 24.04 ou Debian 12/13
- Docker installé (si des bases de données doivent être sauvegardées)
- Accès root ou sudo
- Connectivité Tailscale vers la gateway

---

## 1. Mise en place de la gateway

### 1.1 Provisionner la VM

Créer une VM Linux (Ubuntu 24.04 recommandé) sur le même réseau que le Synology.

### 1.2 Installer Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Noter l'IP Tailscale de la gateway (ex: `100.x.y.z`).

### 1.3 Préparer le partage Synology

Sur le Synology (DSM) :

1. Créer un dossier partagé `backups`
2. Créer un utilisateur local `backup-svc` avec accès au dossier
3. Activer SMB (Panneau de configuration → Services de fichiers → SMB)

### 1.4 Exécuter le setup

```bash
git clone https://github.com/computile/computile-backup-agent.git
cd computile-backup-agent/gateway
sudo ./setup_gateway.sh
```

Le script va :
- Installer les paquets nécessaires (cifs-utils, openssh-server, fail2ban)
- Configurer le montage SMB vers le Synology
- Configurer SSH (chroot SFTP, clés uniquement)
- Activer fail2ban

### 1.5 Vérifier le montage

```bash
df -h /srv/backups
ls -la /srv/backups
```

---

## 2. Créer un utilisateur de backup

Pour chaque client :

```bash
sudo ./create_backup_user.sh client-a --vps vps-prod-01
```

Cela crée :
- Un utilisateur système `backup-client-a`
- Un répertoire chrooted `/srv/backups/client-a/`
- Un sous-dossier `/srv/backups/client-a/data/vps-prod-01/`

---

## 3. Générer les clés SSH (sur le VPS)

> **Note** : l'installeur interactif (`install.sh`) génère automatiquement la clé SSH et configure `/root/.ssh/config`. Cette section est utile si vous configurez la clé manuellement.

Sur le VPS client :

```bash
sudo ssh-keygen -t ed25519 -f /root/.ssh/backup_ed25519 -N "" -C "backup-vps-prod-01"
```

Copier la clé publique sur la gateway :

```bash
# Depuis le VPS
sudo cat /root/.ssh/backup_ed25519.pub | ssh admin@<gateway-ip> \
    "sudo tee -a /srv/backups/client-a/.ssh/authorized_keys"
```

Ou utiliser le script de création avec `--key` :

```bash
# Sur la gateway
sudo ./create_backup_user.sh client-a --key /tmp/backup_ed25519.pub
```

### Configurer le client SSH

Créer `/root/.ssh/config` sur le VPS :

```
Host backup-gateway
    HostName 100.x.y.z
    User backup-client-a
    IdentityFile /root/.ssh/backup_ed25519
    StrictHostKeyChecking accept-new
```

Tester la connexion :

```bash
sudo sftp backup-gateway
# Devrait ouvrir une session SFTP dans /data/
```

---

## 4. Installer l'agent de backup (sur le VPS)

```bash
git clone https://github.com/computile/computile-backup-agent.git
cd computile-backup-agent/client
sudo ./install.sh
```

L'installeur lance un **assistant interactif** qui guide la configuration (identité, repository, chemins, Docker, email, healthcheck, rétention). Il peut aussi être lancé en mode non-interactif avec `--non-interactive` (utilise alors le fichier de config exemple).

Le script installe :
- restic (binaire officiel)
- msmtp (pour les notifications email)
- Le script principal dans `/usr/local/bin/computile-backup`
- Les librairies dans `/usr/local/lib/computile-backup/`
- La configuration dans `/etc/computile-backup/` (générée par l'assistant)
- Les unités systemd (service + timer)
- La configuration logrotate (`/etc/logrotate.d/computile-backup`)
- Génère une clé SSH ed25519 et configure `/root/.ssh/config`
- Génère un mot de passe restic aléatoire

---

## 5. Configurer l'agent

> **Note** : si vous avez utilisé l'installeur interactif, la configuration est déjà générée. Cette section est utile pour les ajustements post-installation ou le mode `--non-interactive`.

### 5.1 Éditer la configuration principale

```bash
sudo nano /etc/computile-backup/backup-agent.conf
```

Paramètres essentiels à modifier :

```bash
CLIENT_ID="client-a"
HOST_ID="vps-prod-01"
RESTIC_REPOSITORY="sftp:backup-client-a@backup-gateway:/srv/backups/backup-client-a/data/vps-prod-01"
```

### 5.2 Configurer le mot de passe SMTP

```bash
echo "votre-mot-de-passe-smtp" | sudo tee /etc/computile-backup/smtp-password
sudo chmod 600 /etc/computile-backup/smtp-password
```

### 5.3 Vérifier les exclusions

```bash
sudo nano /etc/computile-backup/excludes.txt
```

### 5.4 Sauvegarder le mot de passe restic

```bash
sudo cat /etc/computile-backup/restic-password
# CONSERVER CE MOT DE PASSE EN LIEU SÛR
# Il est indispensable pour restaurer les backups
```

---

## 6. Initialiser le repository restic

```bash
sudo computile-backup --init --dry-run --verbose
```

Si tout est OK, lancer sans `--dry-run` :

```bash
sudo computile-backup --init
```

---

## 7. Tester le backup

```bash
# Test complet avec sortie détaillée
sudo computile-backup --verbose

# Vérifier le snapshot
sudo restic -r "sftp:backup-client-a@backup-gateway:/srv/backups/backup-client-a/data/vps-prod-01" \
    --password-file /etc/computile-backup/restic-password \
    snapshots
```

---

## 8. Activer le timer systemd

```bash
sudo systemctl enable --now computile-backup.timer

# Vérifier
systemctl list-timers computile-backup.timer
```

Le backup s'exécutera chaque nuit à 02:15 (± 15 min de jitter).

---

## Récapitulatif des fichiers de secrets

| Fichier | Contenu | Permissions |
|---------|---------|-------------|
| `/etc/computile-backup/restic-password` | Mot de passe du repo restic | `600` |
| `/etc/computile-backup/smtp-password` | Mot de passe SMTP OVH | `600` |
| `/root/.ssh/backup_ed25519` | Clé privée SSH pour la gateway | `600` |
| (gateway) `/root/.smb-credentials` | Credentials SMB Synology | `600` |
