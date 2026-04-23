# ✍️ SignApp — Application de Signature Électronique

Application web interne permettant à un **gestionnaire PC** d'envoyer des documents PDF à signer à une **tablette**, avec génération automatique du PDF final signé.

![PHP](https://img.shields.io/badge/PHP-8.1%2B-777BB4?logo=php&logoColor=white)
![Nginx](https://img.shields.io/badge/Nginx-009639?logo=nginx&logoColor=white)
![Apache](https://img.shields.io/badge/Apache-D22128?logo=apache&logoColor=white)
![License](https://img.shields.io/badge/Licence-MIT-blue)

---

## 📋 Sommaire

- [Fonctionnement](#-fonctionnement)
- [Stack technique](#-stack-technique)
- [Prérequis](#-prérequis)
- [Installation rapide](#-installation-rapide)
- [Installation manuelle](#-installation-manuelle)
- [Structure du projet](#-structure-du-projet)
- [Configuration](#-configuration)
- [Utilisation](#-utilisation)
- [Sécurité](#-sécurité)
- [Dépannage](#-dépannage)
- [Contribuer](#-contribuer)

---

## 🔄 Fonctionnement

```
[PC Gestionnaire]                    [Tablette]
      │                                   │
      │ 1. Upload PDF                     │
      │ 2. Saisie noms signataires        │
      │ 3. Placement zones de signature   │
      │ 4. Envoi à la tablette ─────────► │
      │                                   │ 5. Lecture du document
      │                                   │ 6. Signature tactile x2
      │ ◄──────────────────────────────── │
      │ 7. PDF final disponible           │
      │ 8. Téléchargement                 │
```

**Cycle de vie d'un document :**

```
draft → zones_placed → waiting_signatures → signed_by_1 → completed
```

---

## 🛠️ Stack technique

| Composant | Rôle |
|-----------|------|
| **PHP 8.1+** | Backend API REST, gestion sessions, génération PDF |
| **TCPDF 6.7.5** | Création/manipulation de PDF |
| **FPDI 2.6.1** | Import de PDF existants dans TCPDF |
| **Ghostscript** | Conversion PDF→PNG (prévisualisations) + compatibilité FPDI |
| **Nginx / Apache** | Serveur web |
| **JavaScript Vanilla** | Interface PC et tablette, canvas de signature |

> Pas de base de données — les documents sont stockés sous forme de **fichiers JSON** dans `storage/sessions/`.

---

## 📦 Prérequis

| Composant | Version minimale |
|-----------|-----------------|
| OS | Debian 11+ / Ubuntu 20.04+ |
| PHP | 8.1+ |
| Extensions PHP | `gd`, `imagick`, `mbstring`, `xml`, `curl`, `zip` |
| Ghostscript | Toute version récente |
| Poppler | `pdfinfo` |
| Espace disque | 500 Mo minimum |
| Accès Internet | Pour le déploiement automatique (téléchargement libs) |

---

## 🚀 Installation rapide

Le script `deploy_signapp.sh` automatise **l'intégralité** de l'installation.

### 1. Préparer l'archive des sources

```bash
git clone https://github.com/votre-user/signapp.git
cd signapp

tar czf /tmp/signapp_sources.tar.gz \
  --exclude='signature/storage/*' \
  --exclude='signature/libs/tcpdf' \
  --exclude='signature/libs/FPDI' \
  signature/

base64 /tmp/signapp_sources.tar.gz > /tmp/signapp_sources.b64
```

### 2. Assembler le script de déploiement

```bash
cp deploy_signapp.sh /tmp/deploy_signapp.sh

# Injecter le b64 entre les marqueurs
cat /tmp/signapp_sources.b64 >> /tmp/deploy_signapp.sh
echo "__SOURCES_B64_END__" >> /tmp/deploy_signapp.sh

# Vérifier
tail -3 /tmp/deploy_signapp.sh
```

### 3. Lancer le déploiement

```bash
chmod +x /tmp/deploy_signapp.sh
sudo bash /tmp/deploy_signapp.sh
```

Le script est **interactif** : il vous demandera le chemin d'installation, le serveur web, le nom de domaine, les identifiants et le mode HTTPS.

### 4. Ce que le script fait automatiquement

| Étape | Action |
|-------|--------|
| ✅ Vérifications | Root, OS Debian/Ubuntu |
| 📦 Paquets | Nginx/Apache, PHP, Ghostscript, ImageMagick, Poppler |
| 🔓 ImageMagick | Débloque la conversion PDF |
| 📁 Structure | Crée `storage/` et sous-dossiers |
| 📚 Librairies | Télécharge TCPDF 6.7.5 + FPDI 2.6.1 depuis GitHub |
| 🔐 Secrets | Génère une `SECRET_KEY` aléatoire, hashe les mots de passe |
| 📝 Config | Patch `config.php` avec vos identifiants |
| ⚙️ PHP | Ajuste `upload_max_filesize`, `memory_limit`, timeouts |
| 🌐 Vhost | Configure Nginx **ou** Apache |
| 🔒 HTTPS | Let's Encrypt, auto-signé, ou aucun (au choix) |
| ⏰ Cron | Nettoyage quotidien à 3h du matin |
| 🧪 Tests | Vérifie TCPDF, FPDI, Imagick, HTTP |

---

## 🔧 Installation manuelle

### 1. Paquets système

```bash
sudo apt update
sudo apt install -y \
    nginx php8.2-fpm php8.2-gd php8.2-imagick \
    php8.2-mbstring php8.2-xml \
    ghostscript imagemagick poppler-utils \
    wget curl
```

### 2. Autoriser ImageMagick à lire les PDF

```bash
sudo nano /etc/ImageMagick-6/policy.xml
# Trouver :   <policy domain="coder" rights="none" pattern="PDF" />
# Remplacer : <policy domain="coder" rights="read|write" pattern="PDF" />
```

### 3. Déployer les sources

```bash
sudo mkdir -p /raid/signature
sudo cp -r signature/* /raid/signature/
```

### 4. Installer les librairies

```bash
cd /raid/signature/libs

# TCPDF
wget https://github.com/tecnickcom/TCPDF/archive/refs/tags/6.7.5.tar.gz -O tcpdf.tar.gz
tar xzf tcpdf.tar.gz && mv TCPDF-6.7.5 tcpdf && rm tcpdf.tar.gz

# FPDI
wget https://github.com/Setasign/FPDI/archive/refs/tags/v2.6.1.tar.gz -O fpdi.tar.gz
tar xzf fpdi.tar.gz && mv FPDI-2.6.1 FPDI && rm fpdi.tar.gz

ls tcpdf/tcpdf.php && echo "TCPDF OK"
ls FPDI/src/autoload.php && echo "FPDI OK"
```

### 5. Permissions

```bash
sudo chown -R www-data:www-data /raid/signature
sudo find /raid/signature -type d -exec chmod 750 {} \;
sudo find /raid/signature -type f -exec chmod 640 {} \;
sudo chmod -R 770 /raid/signature/storage
sudo chmod 700 /raid/signature/storage/php_sessions
```

### 6. Configuration

```bash
# Générer une SECRET_KEY
php -r 'echo bin2hex(random_bytes(32));'

# Générer les hashs de mots de passe
php -r "echo password_hash('VotreMotDePasse', PASSWORD_BCRYPT);"
```

Éditez ensuite `config/config.php` avec les valeurs générées.

---

## 📁 Structure du projet

```
signature/
├── config/
│   └── config.php              # Configuration centrale (chemins, users, fonctions)
├── api/
│   ├── upload.php              # POST — Upload PDF + génération previews
│   ├── preview.php             # GET  — Servir les images de prévisualisation
│   ├── set_zones.php           # POST — Enregistrer les zones de signature
│   ├── send_to_tablet.php      # POST — Basculer le doc vers la tablette
│   ├── status.php              # GET  — Suivi de statut (PC et tablette)
│   ├── sign.php                # POST — Enregistrer une signature + générer PDF final
│   └── download.php            # GET  — Télécharger le PDF signé
├── assets/
│   ├── css/
│   │   ├── style.css           # Styles communs
│   │   ├── pc.css              # Styles interface gestionnaire
│   │   └── tablet.css          # Styles interface tablette
│   └── js/
│       ├── pc.js               # Logique PC (upload, zones, suivi)
│       ├── tablet.js           # Logique tablette (liste, lecture, signature)
│       └── signature_canvas.js # Module canvas tactile réutilisable
├── pc/
│   └── index.php               # Interface gestionnaire PC
├── tablet/
│   └── index.php               # Interface tablette
├── login.php                   # Page de connexion commune
├── logout.php                  # Déconnexion
├── cleanup.php                 # Nettoyage des documents expirés (cron)
├── libs/                       # ⚠️ Non versionné — installé par le script
│   ├── tcpdf/
│   ├── FPDI/
│   └── .htaccess               # Bloque l'accès web direct aux libs
└── storage/                    # ⚠️ Non versionné (.gitignore)
    ├── pdf/                    # PDFs uploadés originaux
    ├── previews/               # Images PNG de prévisualisation
    ├── sessions/               # JSON d'état des documents
    ├── signatures/             # Images PNG des signatures
    ├── final/                  # PDFs finaux signés
    └── php_sessions/           # Sessions PHP
```

---

## ⚙️ Configuration

Le fichier `config/config.php` centralise toute la configuration :

```php
<?php
declare(strict_types=1);

// Clé secrète (générée automatiquement par le script de déploiement)
define('SECRET_KEY', 'votre_cle_64_caracteres');

// Utilisateurs (mots de passe hashés bcrypt)
define('USERS', [
    'gestionnaire' => [
        'password_hash' => '$2y$10$...',
        'role'          => 'pc',
    ],
    'tablette' => [
        'password_hash' => '$2y$10$...',
        'role'          => 'tablet',
    ],
]);

// Chemins de stockage
define('STORAGE_PATH',       '/raid/signature/storage');
define('PDF_UPLOAD_PATH',    STORAGE_PATH . '/pdf');
define('PREVIEW_PATH',       STORAGE_PATH . '/previews');
define('SESSION_PATH',       STORAGE_PATH . '/sessions');
define('SIGNATURE_PATH',     STORAGE_PATH . '/signatures');
define('FINAL_PDF_PATH',     STORAGE_PATH . '/final');

// Limites
define('MAX_FILE_SIZE_MB',   20);
define('SESSION_LIFETIME',   3600);
define('CLEANUP_AFTER_DAYS', 7);
```

---

## 💻 Utilisation

### Interface PC (Gestionnaire)

1. Connectez-vous avec le compte `pc`
2. **Uploadez** un PDF (max 20 Mo par défaut)
3. **Placez les zones** de signature sur le document (glisser-déposer)
4. **Entrez les noms** des deux signataires
5. **Envoyez à la tablette** — le statut passe à `waiting_signatures`
6. **Attendez** la confirmation (polling automatique toutes les 5s)
7. **Téléchargez** le PDF final signé

### Interface Tablette

1. Connectez-vous avec le compte `tablet`
2. **Sélectionnez** le document en attente
3. **Lisez** le document (défilement page par page)
4. **Signez** dans chaque zone avec le doigt ou le stylet
5. **Validez** — le PDF final est généré automatiquement

---

## 🔒 Sécurité

| Mesure | Détail |
|--------|--------|
| Authentification | Sessions PHP + mots de passe bcrypt |
| Protection CSRF | Token par session, vérifié sur chaque POST |
| Upload | Vérification MIME + extension + taille |
| Accès fichiers | `storage/` et `libs/` bloqués par `.htaccess` / vhost |
| Headers HTTP | `X-Frame-Options`, `X-Content-Type-Options`, `CSP` |
| Pas de données sensibles | Aucun mot de passe en clair, aucune clé en dur dans le code |

> ⚠️ **Important** : Changez impérativement la `SECRET_KEY` et les mots de passe par défaut avant toute mise en production.

---

## 🔁 Mise à jour

```bash
# Sauvegarder la config actuelle
sudo cp /raid/signature/config/config.php /tmp/config_backup.php

# Relancer le script de déploiement (préserve storage/)
sudo bash /tmp/deploy_signapp_nouveau.sh

# Restaurer la config si nécessaire
sudo cp /tmp/config_backup.php /raid/signature/config/config.php
sudo systemctl reload nginx   # ou apache2
```

---

## 🐛 Dépannage

### FPDI lève une exception sur certains PDF

```bash
# Le PDF source est peut-être en PDF 1.5+ (object streams)
# Ghostscript doit être installé pour la décompression automatique
which gs && gs --version

# Test manuel
gs -q -dNOPAUSE -dBATCH -sDEVICE=pdfwrite \
   -dCompatibilityLevel=1.4 \
   -sOutputFile=/tmp/test_compat.pdf \
   /chemin/vers/votre.pdf
```

### Prévisualisations manquantes

```bash
# Vérifier Ghostscript et Poppler
which gs && which pdfinfo

# Test de conversion
gs -q -dNOPAUSE -dBATCH -sDEVICE=png16m -r120 \
   -sOutputFile=/tmp/page_%d.png /chemin/vers/votre.pdf

ls -la /tmp/page_*.png
```

### Problème de permissions

```bash
# Vérifier que www-data peut écrire
sudo -u www-data touch /raid/signature/storage/sessions/test && echo "OK" || echo "KO"
sudo rm -f /raid/signature/storage/sessions/test

# Corriger si nécessaire
sudo chown -R www-data:www-data /raid/signature/storage
sudo chmod -R 770 /raid/signature/storage
```

### Session perdue / CSRF invalide

```bash
# Vérifier le chemin des sessions PHP
ls -la /raid/signature/storage/php_sessions/
sudo -u www-data touch /raid/signature/storage/php_sessions/test && echo "OK"

# Vérifier php.ini
php -r "echo ini_get('session.save_path');"
```

### Logs utiles

```bash
# Nginx
sudo tail -f /var/log/nginx/error.log

# Apache
sudo tail -f /var/log/apache2/signature_error.log

# Nettoyage cron
tail -f /var/log/signature_cleanup.log

# Sessions documents actifs
ls -la /raid/signature/storage/sessions/*.json
```

---

## 🤝 Contribuer

1. Forkez le dépôt
2. Créez une branche : `git checkout -b feature/ma-fonctionnalite`
3. Commitez : `git commit -m "feat: description claire"`
4. Poussez : `git push origin feature/ma-fonctionnalite`
5. Ouvrez une Pull Request

### Conventions de commit

```
feat:     nouvelle fonctionnalité
fix:      correction de bug
docs:     documentation
refactor: refactoring sans changement de comportement
chore:    maintenance (deps, config...)
```

---

## 📄 Licence

MIT — voir [LICENSE](LICENSE)

---

## 👤 Auteur

Développé pour un usage interne. Contributions bienvenues.

---

*Dernière mise à jour : Avril 2026*

