#!/usr/bin/env bash
#==============================================================================
# deploy_signapp.sh — Déploiement automatisé de l'application Signature
#
# Usage : sudo bash deploy_signapp.sh
#
# Prérequis : Debian 11/12 ou Ubuntu 22.04+
#             Accès Internet (apt + GitHub)
#
# Le b64 de l'archive des sources est embarqué à la fin du script,
# entre les marqueurs __SOURCES_B64_START__ et __SOURCES_B64_END__.
#==============================================================================
set -euo pipefail

#------------------------------------------------------------------------------
# Couleurs & helpers
#------------------------------------------------------------------------------
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; BLU='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLU}[*]${NC} $*"; }
ok()   { echo -e "${GRN}[OK]${NC} $*"; }
warn() { echo -e "${YLW}[!]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

#------------------------------------------------------------------------------
# Vérifications préliminaires
#------------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Ce script doit être exécuté en root (sudo)."
command -v apt-get >/dev/null || die "Système non supporté (apt-get absent)."

. /etc/os-release
log "Distribution détectée : ${PRETTY_NAME:-inconnue}"

#------------------------------------------------------------------------------
# Saisie interactive
#------------------------------------------------------------------------------
echo
echo "==================================================================="
echo "  INSTALLATION APPLICATION SIGNATURE ÉLECTRONIQUE"
echo "==================================================================="
echo

read -rp "Chemin d'installation [/raid/signature] : " INSTALL_DIR
INSTALL_DIR="${INSTALL_DIR:-/raid/signature}"

read -rp "Serveur web (nginx/apache) [nginx] : " WEBSERVER
WEBSERVER="${WEBSERVER:-nginx}"
[[ "$WEBSERVER" =~ ^(nginx|apache)$ ]] || die "Serveur web invalide."

read -rp "Nom de domaine ou IP pour le vhost [signature.local] : " SERVER_NAME
SERVER_NAME="${SERVER_NAME:-signature.local}"

read -rp "Activer HTTPS ? (none/selfsigned/letsencrypt) [none] : " HTTPS_MODE
HTTPS_MODE="${HTTPS_MODE:-none}"

echo
echo "--- Identifiants utilisateur PC (gestionnaire) ---"
read -rp "Login PC [gestionnaire] : " PC_LOGIN
PC_LOGIN="${PC_LOGIN:-gestionnaire}"
read -srp "Mot de passe PC : " PC_PASS; echo
[[ -n "$PC_PASS" ]] || die "Le mot de passe PC ne peut pas être vide."

echo
echo "--- Identifiants utilisateur Tablette ---"
read -rp "Login Tablette [tablette] : " TAB_LOGIN
TAB_LOGIN="${TAB_LOGIN:-tablette}"
read -srp "Mot de passe Tablette : " TAB_PASS; echo
[[ -n "$TAB_PASS" ]] || die "Le mot de passe Tablette ne peut pas être vide."

echo
log "Récapitulatif :"
echo "  - Installation      : $INSTALL_DIR"
echo "  - Serveur web       : $WEBSERVER"
echo "  - Nom de domaine    : $SERVER_NAME"
echo "  - HTTPS             : $HTTPS_MODE"
echo "  - Login PC          : $PC_LOGIN"
echo "  - Login Tablette    : $TAB_LOGIN"
echo
read -rp "Confirmer et lancer l'installation ? (o/N) : " CONFIRM
[[ "$CONFIRM" =~ ^[oOyY]$ ]] || die "Installation annulée."

#------------------------------------------------------------------------------
# Installation des paquets
#------------------------------------------------------------------------------
log "Mise à jour des paquets apt..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

COMMON_PKGS=(
    ghostscript imagemagick poppler-utils
    php-cli php-gd php-imagick php-mbstring php-xml php-curl php-zip
    curl wget ca-certificates unzip tar openssl
)

if [[ "$WEBSERVER" == "nginx" ]]; then
    WEB_PKGS=(nginx php-fpm)
else
    WEB_PKGS=(apache2 libapache2-mod-php)
fi

log "Installation des paquets..."
apt-get install -y -qq "${COMMON_PKGS[@]}" "${WEB_PKGS[@]}"
ok "Paquets installés."

# Détection version PHP
PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
log "PHP détecté : $PHP_VERSION"

#------------------------------------------------------------------------------
# Correction ImageMagick policy pour PDF
#------------------------------------------------------------------------------
log "Ajustement de la policy ImageMagick pour PDF..."
for POLICY_FILE in /etc/ImageMagick-6/policy.xml /etc/ImageMagick-7/policy.xml; do
    if [[ -f "$POLICY_FILE" ]]; then
        cp -n "$POLICY_FILE" "$POLICY_FILE.bak" || true
        sed -i 's|<policy domain="coder" rights="none" pattern="PDF" */>|<policy domain="coder" rights="read\|write" pattern="PDF" />|g' "$POLICY_FILE"
        sed -i 's|<policy domain="coder" rights="none" pattern="PS" */>|<policy domain="coder" rights="read\|write" pattern="PS" />|g' "$POLICY_FILE"
        sed -i 's|<policy domain="coder" rights="none" pattern="EPS" */>|<policy domain="coder" rights="read\|write" pattern="EPS" />|g' "$POLICY_FILE"
        ok "Policy ImageMagick ajustée ($POLICY_FILE)."
    fi
done

#------------------------------------------------------------------------------
# Extraction des sources embarquées
#------------------------------------------------------------------------------
log "Création du dossier d'installation : $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# Le dossier parent doit être traversable pour www-data
PARENT_DIR=$(dirname "$INSTALL_DIR")
chmod o+x "$PARENT_DIR" 2>/dev/null || true

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

log "Extraction des sources embarquées..."
awk '/^__SOURCES_B64_START__$/{flag=1; next} /^__SOURCES_B64_END__$/{flag=0} flag' "$0" \
    | base64 -d > "$TMPDIR/sources.tar.gz"

[[ -s "$TMPDIR/sources.tar.gz" ]] || die "Archive b64 introuvable ou vide dans le script."

# Vérification SHA256 (warning uniquement si différent)
EXPECTED_SHA="504ffd77bec21de63c63c7b2c7e2ef03e7306b251b76c330ad29e0e03f023470"
ACTUAL_SHA=$(sha256sum "$TMPDIR/sources.tar.gz" | awk '{print $1}')
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
    warn "SHA256 de l'archive différent de l'attendu ($ACTUAL_SHA)"
    warn "(si tu as régénéré l'archive, c'est normal — mets à jour EXPECTED_SHA)"
else
    ok "Archive vérifiée (SHA256 OK)."
fi

# Extraction dans un sous-dossier temporaire (pour préserver storage/ si upgrade)
mkdir -p "$TMPDIR/extract"
tar -xzf "$TMPDIR/sources.tar.gz" -C "$TMPDIR/extract"

# L'archive contient "signature/", on copie son contenu
cp -a "$TMPDIR/extract/signature/." "$INSTALL_DIR/"
ok "Sources extraites dans $INSTALL_DIR"

#------------------------------------------------------------------------------
# Génération des secrets et remplacement dans config.php
#------------------------------------------------------------------------------
CONFIG_FILE="$INSTALL_DIR/config/config.php"
[[ -f "$CONFIG_FILE" ]] || die "config.php introuvable après extraction."

log "Génération de la clé secrète et des hashs de mots de passe..."
SECRET_KEY=$(php -r 'echo bin2hex(random_bytes(32));')
PC_HASH=$(PC_PASS="$PC_PASS" php -r 'echo password_hash(getenv("PC_PASS"), PASSWORD_BCRYPT);')
TAB_HASH=$(TAB_PASS="$TAB_PASS" php -r 'echo password_hash(getenv("TAB_PASS"), PASSWORD_BCRYPT);')

# Script PHP externe (évite les soucis de heredoc avec $)
PATCH_SCRIPT="$TMPDIR/patch_config.php"
cat > "$PATCH_SCRIPT" <<'PHPEOF'
<?php
$file       = getenv('CFG_FILE');
$secret     = getenv('CFG_SECRET');
$pc_hash    = getenv('CFG_PC_HASH');
$tab_hash   = getenv('CFG_TAB_HASH');
$pc_login   = getenv('CFG_PC_LOGIN');
$tab_login  = getenv('CFG_TAB_LOGIN');

$c = file_get_contents($file);
if ($c === false) { fwrite(STDERR, "Cannot read $file\n"); exit(1); }

// 1. SECRET_KEY
$c = preg_replace(
    "/define\(\s*'SECRET_KEY'\s*,\s*'[^']*'\s*\)\s*;/",
    "define('SECRET_KEY', '" . $secret . "');",
    $c, 1
);

// 2. Hash gestionnaire — remplacement par callback pour éviter l'interprétation des $
$c = preg_replace_callback(
    "/('gestionnaire'\s*=>\s*\[\s*'password_hash'\s*=>\s*')[^']+(')/",
    function($m) use ($pc_hash) { return $m[1] . $pc_hash . $m[2]; },
    $c, 1
);
// Cas alternatif avec clé 'admin'
$c = preg_replace_callback(
    "/('admin'\s*=>\s*\[\s*'password_hash'\s*=>\s*')[^']+(')/",
    function($m) use ($pc_hash) { return $m[1] . $pc_hash . $m[2]; },
    $c, 1
);

// 3. Hash tablette
$c = preg_replace_callback(
    "/('tablette'\s*=>\s*\[\s*'password_hash'\s*=>\s*')[^']+(')/",
    function($m) use ($tab_hash) { return $m[1] . $tab_hash . $m[2]; },
    $c, 1
);

// 4. Renommage clés login
if ($pc_login !== 'gestionnaire' && $pc_login !== '') {
    $c = preg_replace("/'gestionnaire'(\s*=>\s*\[)/", "'" . $pc_login . "'$1", $c, 1);
}
if ($tab_login !== 'tablette' && $tab_login !== '') {
    $c = preg_replace("/'tablette'(\s*=>\s*\[)/", "'" . $tab_login . "'$1", $c, 1);
}

if (file_put_contents($file, $c) === false) {
    fwrite(STDERR, "Cannot write $file\n"); exit(1);
}
echo "Config patched OK\n";
PHPEOF

CFG_FILE="$CONFIG_FILE" \
CFG_SECRET="$SECRET_KEY" \
CFG_PC_HASH="$PC_HASH" \
CFG_TAB_HASH="$TAB_HASH" \
CFG_PC_LOGIN="$PC_LOGIN" \
CFG_TAB_LOGIN="$TAB_LOGIN" \
php "$PATCH_SCRIPT" || die "Erreur lors du patch de config.php"

# Vérifications
if grep -qE "__SECRET_KEY__|__PC_PASSWORD_HASH__|__TABLET_PASSWORD_HASH__|CHANGE_ME_64_CHARS" "$CONFIG_FILE"; then
    die "Un placeholder n'a pas été remplacé dans config.php."
fi
php -l "$CONFIG_FILE" >/dev/null || die "config.php contient une erreur de syntaxe après patch."
ok "Configuration générée et validée."

#------------------------------------------------------------------------------
# Ajustement des chemins absolus dans config.php
#------------------------------------------------------------------------------
if [[ "$INSTALL_DIR" != "/raid/signature" ]]; then
    log "Ajustement des chemins (INSTALL_DIR personnalisé)..."
    sed -i "s|/raid/signature|$INSTALL_DIR|g" "$CONFIG_FILE"
    ok "Chemins ajustés."
fi

# Syntaxe PHP
php -l "$CONFIG_FILE" >/dev/null || die "config.php contient une erreur de syntaxe après modifications."

#------------------------------------------------------------------------------
# Téléchargement des librairies (TCPDF + FPDI)
#------------------------------------------------------------------------------
log "Téléchargement de TCPDF et FPDI..."
LIBS_DIR="$INSTALL_DIR/libs"
mkdir -p "$LIBS_DIR"

# TCPDF
if [[ ! -f "$LIBS_DIR/tcpdf/tcpdf.php" ]]; then
    TCPDF_VER="6.7.5"
    log "  -> TCPDF $TCPDF_VER"
    wget -q "https://github.com/tecnickcom/TCPDF/archive/refs/tags/$TCPDF_VER.tar.gz" -O "$TMPDIR/tcpdf.tar.gz"
    tar -xzf "$TMPDIR/tcpdf.tar.gz" -C "$TMPDIR"
    rm -rf "$LIBS_DIR/tcpdf"
    mv "$TMPDIR/TCPDF-$TCPDF_VER" "$LIBS_DIR/tcpdf"
    ok "TCPDF $TCPDF_VER installé."
else
    warn "TCPDF déjà présent, passe."
fi

# FPDI — nom de dossier "FPDI" (majuscules) pour coller au code existant
if [[ ! -f "$LIBS_DIR/FPDI/src/autoload.php" ]]; then
    FPDI_VER="2.6.1"
    log "  -> FPDI $FPDI_VER"
    wget -q "https://github.com/Setasign/FPDI/archive/refs/tags/v$FPDI_VER.tar.gz" -O "$TMPDIR/fpdi.tar.gz"
    tar -xzf "$TMPDIR/fpdi.tar.gz" -C "$TMPDIR"
    rm -rf "$LIBS_DIR/FPDI" "$LIBS_DIR/fpdi"
    mv "$TMPDIR/FPDI-$FPDI_VER" "$LIBS_DIR/FPDI"
    # Lien symbolique minuscule pour compat éventuelle
    ln -sfn FPDI "$LIBS_DIR/fpdi"
    ok "FPDI $FPDI_VER installé."
else
    warn "FPDI déjà présent, passe."
fi

# Vérifications clés
[[ -f "$LIBS_DIR/tcpdf/tcpdf.php" ]] || die "TCPDF mal installé (tcpdf.php absent)."
[[ -f "$LIBS_DIR/FPDI/src/autoload.php" ]] || die "FPDI mal installé (autoload absent)."

# .htaccess libs
echo "Require all denied" > "$LIBS_DIR/.htaccess"

#------------------------------------------------------------------------------
# Création des dossiers storage et permissions
#------------------------------------------------------------------------------
log "Création des dossiers storage..."
# Dossiers réels utilisés par l'app (pdf, previews, signatures, sessions, final, php_sessions)
mkdir -p "$INSTALL_DIR/storage"/{pdf,previews,signatures,sessions,final,php_sessions}

# .htaccess storage
echo "Require all denied" > "$INSTALL_DIR/storage/.htaccess"

# cleanup.php (au cas où absent de l'archive)
if [[ ! -f "$INSTALL_DIR/cleanup.php" ]]; then
    cat > "$INSTALL_DIR/cleanup.php" <<'EOF'
<?php
require_once __DIR__ . '/config/config.php';
if (!function_exists('cleanup_storage')) {
    echo date('[Y-m-d H:i:s] ') . 'ERROR: cleanup_storage() not found' . PHP_EOL;
    exit(1);
}
$stats = cleanup_storage();
echo date('[Y-m-d H:i:s] ') . json_encode($stats) . PHP_EOL;
EOF
    log "cleanup.php créé (absent de l'archive)."
fi

WEB_USER="www-data"

log "Application des permissions..."
chown -R "$WEB_USER:$WEB_USER" "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod 750 {} \;
find "$INSTALL_DIR" -type f -exec chmod 640 {} \;
# storage : écriture www-data
chmod -R 770 "$INSTALL_DIR/storage"
chmod 700 "$INSTALL_DIR/storage/php_sessions"
# cleanup.php exécutable
chmod 750 "$INSTALL_DIR/cleanup.php"

# Test écriture effective
if sudo -u "$WEB_USER" touch "$INSTALL_DIR/storage/sessions/.wtest" 2>/dev/null; then
    rm -f "$INSTALL_DIR/storage/sessions/.wtest"
    ok "Permissions OK (www-data peut écrire dans storage/)."
else
    warn "www-data ne peut PAS écrire dans storage/sessions. Vérifie la traversée du chemin $PARENT_DIR."
fi

#------------------------------------------------------------------------------
# Ajustement php.ini
#------------------------------------------------------------------------------
log "Ajustement de php.ini..."
PHP_INI_FILES=(
    "/etc/php/$PHP_VERSION/cli/php.ini"
)
if [[ "$WEBSERVER" == "nginx" ]]; then
    PHP_INI_FILES+=("/etc/php/$PHP_VERSION/fpm/php.ini")
else
    PHP_INI_FILES+=("/etc/php/$PHP_VERSION/apache2/php.ini")
fi

for ini in "${PHP_INI_FILES[@]}"; do
    if [[ -f "$ini" ]]; then
        sed -i 's/^upload_max_filesize.*/upload_max_filesize = 50M/' "$ini"
        sed -i 's/^post_max_size.*/post_max_size = 55M/' "$ini"
        sed -i 's/^memory_limit.*/memory_limit = 256M/' "$ini"
        sed -i 's/^max_execution_time.*/max_execution_time = 120/' "$ini"
        sed -i 's/^session\.gc_maxlifetime.*/session.gc_maxlifetime = 2592000/' "$ini"
    fi
done
ok "php.ini ajusté."

#------------------------------------------------------------------------------
# Configuration vhost
#------------------------------------------------------------------------------
log "Configuration du vhost $WEBSERVER..."

if [[ "$WEBSERVER" == "nginx" ]]; then
    PHP_SOCK=$(ls /run/php/php*-fpm.sock 2>/dev/null | head -1)
    [[ -n "$PHP_SOCK" ]] || die "Socket PHP-FPM introuvable."

    VHOST_FILE="/etc/nginx/sites-available/signature"
    cat > "$VHOST_FILE" <<EOF
server {
    listen 80;
    server_name $SERVER_NAME;
    root $INSTALL_DIR;
    index index.php;

    client_max_body_size 50M;

    # Bloquer accès direct aux dossiers sensibles
    location ~ ^/(config|libs|storage)/ {
        deny all;
        return 403;
    }

    # Fichiers cachés
    location ~ /\.(?!well-known) {
        deny all;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_SOCK;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_read_timeout 120;
    }
}
EOF
    ln -sf "$VHOST_FILE" /etc/nginx/sites-enabled/signature
    rm -f /etc/nginx/sites-enabled/default
    nginx -t || die "Configuration nginx invalide."
    systemctl restart "php$PHP_VERSION-fpm"
    systemctl reload nginx
    ok "Nginx configuré et rechargé."
else
    # Apache
    VHOST_FILE="/etc/apache2/sites-available/signature.conf"
    cat > "$VHOST_FILE" <<EOF
<VirtualHost *:80>
    ServerName $SERVER_NAME
    DocumentRoot $INSTALL_DIR

    <Directory $INSTALL_DIR>
        AllowOverride All
        Require all granted
        DirectoryIndex index.php
    </Directory>

    <DirectoryMatch "^$INSTALL_DIR/(config|libs|storage)">
        Require all denied
    </DirectoryMatch>

    ErrorLog \${APACHE_LOG_DIR}/signature_error.log
    CustomLog \${APACHE_LOG_DIR}/signature_access.log combined
</VirtualHost>
EOF
    a2enmod rewrite headers >/dev/null 2>&1 || true
    a2dissite 000-default >/dev/null 2>&1 || true
    a2ensite signature >/dev/null
    apache2ctl configtest || die "Configuration apache invalide."
    systemctl restart apache2
    ok "Apache configuré et rechargé."
fi

#------------------------------------------------------------------------------
# HTTPS (optionnel)
#------------------------------------------------------------------------------
case "$HTTPS_MODE" in
    letsencrypt)
        log "Installation Let's Encrypt..."
        apt-get install -y -qq certbot
        if [[ "$WEBSERVER" == "nginx" ]]; then
            apt-get install -y -qq python3-certbot-nginx
            certbot --nginx -d "$SERVER_NAME" --non-interactive --agree-tos \
                -m "admin@$SERVER_NAME" --redirect || warn "Certbot a échoué (DNS OK ?)"
        else
            apt-get install -y -qq python3-certbot-apache
            certbot --apache -d "$SERVER_NAME" --non-interactive --agree-tos \
                -m "admin@$SERVER_NAME" --redirect || warn "Certbot a échoué (DNS OK ?)"
        fi
        ;;
    selfsigned)
        log "Génération d'un certificat auto-signé..."
        mkdir -p /etc/ssl/signature
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout /etc/ssl/signature/key.pem \
            -out /etc/ssl/signature/cert.pem \
            -subj "/CN=$SERVER_NAME" 2>/dev/null
        warn "Certificat auto-signé généré dans /etc/ssl/signature/."
        warn "Configuration du vhost HTTPS à faire manuellement."
        ;;
    none|*)
        log "Pas de HTTPS configuré."
        ;;
esac

#------------------------------------------------------------------------------
# Cron cleanup
#------------------------------------------------------------------------------
log "Installation du cron de nettoyage..."
PHP_BIN="/usr/bin/php$PHP_VERSION"
[[ -x "$PHP_BIN" ]] || PHP_BIN="/usr/bin/php"

CRON_LINE="0 3 * * * $PHP_BIN $INSTALL_DIR/cleanup.php >> /var/log/signature_cleanup.log 2>&1"
touch /var/log/signature_cleanup.log
chown "$WEB_USER:$WEB_USER" /var/log/signature_cleanup.log

# Remplace toute ligne existante pointant sur notre cleanup.php
(crontab -u "$WEB_USER" -l 2>/dev/null | grep -v "$INSTALL_DIR/cleanup.php" ; echo "$CRON_LINE") \
    | crontab -u "$WEB_USER" -
ok "Cron installé (3h du matin, utilisateur $WEB_USER)."

#------------------------------------------------------------------------------
# Tests finaux
#------------------------------------------------------------------------------
log "Tests finaux..."

# Syntaxe PHP des fichiers clés
php -l "$CONFIG_FILE" >/dev/null || die "Erreur de syntaxe dans config.php"
[[ -f "$INSTALL_DIR/index.php"  ]] && php -l "$INSTALL_DIR/index.php"  >/dev/null
[[ -f "$INSTALL_DIR/login.php"  ]] && php -l "$INSTALL_DIR/login.php"  >/dev/null
ok "Syntaxe PHP OK."

# Libs
sudo -u "$WEB_USER" php -r "require '$LIBS_DIR/tcpdf/tcpdf.php'; echo 'TCPDF OK'.PHP_EOL;" \
    || warn "TCPDF non fonctionnel."
sudo -u "$WEB_USER" php -r "require '$LIBS_DIR/FPDI/src/autoload.php'; echo 'FPDI OK'.PHP_EOL;" \
    || warn "FPDI non fonctionnel."

# Imagick
php -r 'new Imagick();' 2>/dev/null && ok "Imagick OK." || warn "Imagick non fonctionnel."

# Cleanup à blanc
sudo -u "$WEB_USER" "$PHP_BIN" "$INSTALL_DIR/cleanup.php" >/dev/null 2>&1 \
    && ok "cleanup.php s'exécute sans erreur." \
    || warn "cleanup.php a rencontré un problème (voir manuellement)."

# Test HTTP
sleep 1
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: $SERVER_NAME" "http://127.0.0.1/login.php" || echo "000")
if [[ "$HTTP_CODE" =~ ^(200|302)$ ]]; then
    ok "Test HTTP OK (code $HTTP_CODE)."
else
    warn "Test HTTP : code $HTTP_CODE (à vérifier manuellement)."
fi

#------------------------------------------------------------------------------
# Récapitulatif final
#------------------------------------------------------------------------------
echo
echo "==================================================================="
echo -e "${GRN}  INSTALLATION TERMINÉE AVEC SUCCÈS${NC}"
echo "==================================================================="
echo
echo "  URL d'accès       : http://$SERVER_NAME/"
echo "  Login PC          : $PC_LOGIN"
echo "  Login Tablette    : $TAB_LOGIN"
echo
echo "  Dossier           : $INSTALL_DIR"
echo "  Config            : $CONFIG_FILE"
echo "  Logs nettoyage    : /var/log/signature_cleanup.log"
if [[ "$WEBSERVER" == "nginx" ]]; then
    echo "  Logs nginx        : /var/log/nginx/{access,error}.log"
else
    echo "  Logs apache       : /var/log/apache2/signature_*.log"
fi
echo
echo "  Test manuel du nettoyage :"
echo "    sudo -u $WEB_USER $PHP_BIN $INSTALL_DIR/cleanup.php"
echo
echo "==================================================================="
exit 0

#==============================================================================
# NE PAS ÉDITER CE QUI SUIT — Archive base64 des sources
#==============================================================================
__SOURCES_B64_START__
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
__SOURCES_B64_END__