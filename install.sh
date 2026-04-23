#!/usr/bin/env bash
# ============================================================
# deploy_signapp.sh — Installateur Signature Électronique
# Cible : Ubuntu Server 22.04+ / 24.04
# ============================================================
set -euo pipefail

# ---------- Couleurs ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()   { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR ]${NC} $*" >&2; }
step()  { echo -e "\n${BOLD}${BLUE}=== $* ===${NC}"; }
die()   { err "$*"; exit 1; }

# ---------- Vérifications préalables ----------
[[ $EUID -eq 0 ]] || die "Ce script doit être lancé en root (sudo)."

if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
    warn "OS non Ubuntu détecté. Continuer quand même ? [o/N]"
    read -r r; [[ "$r" =~ ^[oOyY]$ ]] || exit 1
fi

ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 || die "Pas de connexion internet."

# ---------- Questions interactives ----------
step "Configuration de l'installation"

# Chemin
read -rp "Chemin d'installation [/var/www/signature] : " INSTALL_PATH
INSTALL_PATH="${INSTALL_PATH:-/var/www/signature}"
[[ "$INSTALL_PATH" =~ ^/ ]] || die "Chemin absolu requis."

if [[ -d "$INSTALL_PATH" ]]; then
    warn "Le dossier $INSTALL_PATH existe déjà."
    read -rp "Continuer et écraser les fichiers ? [o/N] : " r
    [[ "$r" =~ ^[oOyY]$ ]] || exit 1
fi

# Serveur web
echo ""
echo "Choix du serveur web :"
echo "  1) nginx + PHP-FPM (recommandé)"
echo "  2) Apache2 + mod_php"
read -rp "Choix [1] : " WEB_CHOICE
WEB_CHOICE="${WEB_CHOICE:-1}"
case "$WEB_CHOICE" in
    1) WEB_SERVER="nginx" ;;
    2) WEB_SERVER="apache" ;;
    *) die "Choix invalide." ;;
esac

# Domaine
DEFAULT_HOST="$(hostname -f 2>/dev/null || hostname)"
while true; do
    read -rp "Nom de domaine ou IP d'accès [$DEFAULT_HOST] : " SERVER_NAME
    SERVER_NAME="${SERVER_NAME:-$DEFAULT_HOST}"
    [[ -n "$SERVER_NAME" ]] && break
    warn "Valeur obligatoire."
done

# HTTPS
read -rp "Activer HTTPS avec certificat auto-signé ? [O/n] : " r
if [[ "$r" =~ ^[nN]$ ]]; then
    USE_HTTPS=0
else
    USE_HTTPS=1
fi

# Users
echo ""
log "Configuration des comptes utilisateurs"

while true; do
    read -rp "Login du compte PC (gestionnaire) [gestionnaire] : " PC_USER
    PC_USER="${PC_USER:-gestionnaire}"
    [[ "$PC_USER" =~ ^[a-zA-Z0-9_.-]+$ ]] && break
    warn "Login invalide."
done
while true; do
    read -rsp "Mot de passe PC : " PC_PASS; echo
    [[ ${#PC_PASS} -ge 6 ]] || { warn "Min 6 caractères."; continue; }
    read -rsp "Confirmer : " PC_PASS2; echo
    [[ "$PC_PASS" == "$PC_PASS2" ]] && break
    warn "Ne correspondent pas."
done

while true; do
    read -rp "Login du compte tablette [tablette] : " TAB_USER
    TAB_USER="${TAB_USER:-tablette}"
    [[ "$TAB_USER" =~ ^[a-zA-Z0-9_.-]+$ ]] || { warn "Invalide."; continue; }
    [[ "$TAB_USER" != "$PC_USER" ]] && break
    warn "Doit être différent du login PC."
done
while true; do
    read -rsp "Mot de passe tablette : " TAB_PASS; echo
    [[ ${#TAB_PASS} -ge 6 ]] || { warn "Min 6 caractères."; continue; }
    read -rsp "Confirmer : " TAB_PASS2; echo
    [[ "$TAB_PASS" == "$TAB_PASS2" ]] && break
    warn "Ne correspondent pas."
done

# Récap
echo ""
step "Récapitulatif"
echo "  Installation   : $INSTALL_PATH"
echo "  Serveur web    : $WEB_SERVER"
echo "  Accès          : $([ "$USE_HTTPS" = "1" ] && echo "https" || echo "http")://$SERVER_NAME"
echo "  User PC        : $PC_USER"
echo "  User tablette  : $TAB_USER"
echo ""
read -rp "Lancer l'installation ? [O/n] : " r
[[ "$r" =~ ^[nN]$ ]] && exit 0

# ============================================================
# Installation des paquets
# ============================================================
step "Installation des paquets système"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq software-properties-common ca-certificates curl gnupg lsb-release >/dev/null

# PHP : dernière dispo dans les dépôts Ubuntu
PHP_PKGS="php-fpm php-cli php-gd php-mbstring php-xml php-curl php-zip"
if [[ "$WEB_SERVER" == "apache" ]]; then
    apt-get install -y -qq apache2 libapache2-mod-php $PHP_PKGS >/dev/null
else
    apt-get install -y -qq nginx $PHP_PKGS >/dev/null
fi
apt-get install -y -qq ghostscript poppler-utils openssl unzip cron >/dev/null
ok "Paquets installés"

# Détecter la version de PHP effectivement installée
PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
PHP_FPM_SVC="php${PHP_VER}-fpm"
PHP_FPM_SOCK="/run/php/php${PHP_VER}-fpm.sock"
PHP_INI_FPM="/etc/php/${PHP_VER}/fpm/php.ini"
PHP_INI_APACHE="/etc/php/${PHP_VER}/apache2/php.ini"
log "PHP $PHP_VER détecté"

# ============================================================
# Création arborescence + extraction sources
# ============================================================
step "Création de l'arborescence"

mkdir -p "$INSTALL_PATH"/{api,assets/css,assets/js,config,pc,tablet,libs,storage/{pdf,previews,sessions,signatures,final,php_sessions}}

# Génère SECRET_KEY + hashs
SECRET_KEY="$(openssl rand -hex 32)"
PC_HASH="$(php -r "echo password_hash('$PC_PASS', PASSWORD_BCRYPT);")"
TAB_HASH="$(php -r "echo password_hash('$TAB_PASS', PASSWORD_BCRYPT);")"

# ---------- config/config.php ----------
cat > "$INSTALL_PATH/config/config.php" <<PHPEOF
<?php
// /config/config.php
declare(strict_types=1);

define('SECRET_KEY', '__SECRET_KEY__');

define('ROOT_PATH', dirname(__DIR__));
define('STORAGE_PATH', ROOT_PATH . '/storage');
define('PDF_PATH', STORAGE_PATH . '/pdf');
define('PREVIEW_PATH', STORAGE_PATH . '/previews');
define('SIGNATURES_PATH', STORAGE_PATH . '/signatures');
define('SESSIONS_PATH', STORAGE_PATH . '/sessions');
define('FINAL_PATH', STORAGE_PATH . '/final');
define('LIBS_PATH', ROOT_PATH . '/libs');

define('MAX_PDF_SIZE', 10 * 1024 * 1024);
define('ALLOWED_MIME', ['application/pdf']);

define('SESSION_LIFETIME', 7 * 24 * 3600);
define('TABLET_SESSION_LIFETIME', 30 * 24 * 3600);

define('USERS', [
    '__PC_USER__' => [
        'password_hash' => '__PC_HASH__',
        'role' => 'pc',
        'display_name' => 'Gestionnaire PC'
    ],
    '__TAB_USER__' => [
        'password_hash' => '__TAB_HASH__',
        'role' => 'tablet',
        'display_name' => 'Tablette Signature'
    ],
]);

if (session_status() === PHP_SESSION_NONE) {
    session_set_cookie_params([
        'lifetime' => SESSION_LIFETIME,
        'path' => '/',
        'domain' => '',
        'secure' => (!empty(\$_SERVER['HTTPS']) && \$_SERVER['HTTPS'] !== 'off'),
        'httponly' => true,
        'samesite' => 'Strict',
    ]);
    ini_set('session.use_strict_mode', '1');
    ini_set('session.use_only_cookies', '1');
    ini_set('session.save_path', '__SESSION_PATH__');
    ini_set('session.gc_maxlifetime', (string)TABLET_SESSION_LIFETIME);
    ini_set('session.cookie_lifetime', (string)TABLET_SESSION_LIFETIME);
    session_name('SIGNAPP_SESSID');
    session_start();
}

header('X-Frame-Options: DENY');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: no-referrer');
header("Content-Security-Policy: default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self';");

foreach ([STORAGE_PATH, PDF_PATH, PREVIEW_PATH, SIGNATURES_PATH, SESSIONS_PATH, FINAL_PATH] as \$dir) {
    if (!is_dir(\$dir)) { @mkdir(\$dir, 0755, true); }
}

function generate_csrf_token(): string {
    if (empty(\$_SESSION['csrf_token'])) {
        \$_SESSION['csrf_token'] = bin2hex(random_bytes(32));
    }
    return \$_SESSION['csrf_token'];
}

function verify_csrf_token(?string \$token): bool {
    return !empty(\$token) && !empty(\$_SESSION['csrf_token'])
        && hash_equals(\$_SESSION['csrf_token'], \$token);
}

function require_role(string \$role): void {
    if (empty(\$_SESSION['user']) || (\$_SESSION['user']['role'] ?? '') !== \$role) {
        header('Location: /login.php'); exit;
    }
    if (!empty(\$_SESSION['user']['login_time'])) {
        \$lifetime = (\$role === 'tablet') ? TABLET_SESSION_LIFETIME : SESSION_LIFETIME;
        if (time() - \$_SESSION['user']['login_time'] > \$lifetime) {
            session_unset(); session_destroy();
            header('Location: /login.php?expired=1'); exit;
        }
    }
}

function json_response(array \$data, int \$code = 200): void {
    http_response_code(\$code);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode(\$data); exit;
}

function load_document(string \$doc_id): ?array {
    \$doc_id = preg_replace('/[^a-f0-9]/', '', \$doc_id);
    if (strlen(\$doc_id) < 16) return null;
    \$file = SESSIONS_PATH . '/' . \$doc_id . '.json';
    if (!is_file(\$file)) return null;
    \$fp = fopen(\$file, 'r'); if (!\$fp) return null;
    flock(\$fp, LOCK_SH);
    \$content = stream_get_contents(\$fp);
    flock(\$fp, LOCK_UN); fclose(\$fp);
    \$data = json_decode(\$content, true);
    return is_array(\$data) ? \$data : null;
}

function save_document(string \$doc_id, array \$data): bool {
    \$doc_id = preg_replace('/[^a-f0-9]/', '', \$doc_id);
    if (strlen(\$doc_id) < 16) return false;
    \$file = SESSIONS_PATH . '/' . \$doc_id . '.json';
    \$fp = fopen(\$file, 'c+'); if (!\$fp) return false;
    flock(\$fp, LOCK_EX);
    ftruncate(\$fp, 0); rewind(\$fp);
    fwrite(\$fp, json_encode(\$data, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
    fflush(\$fp);
    flock(\$fp, LOCK_UN); fclose(\$fp);
    return true;
}

function get_active_document_for_tablet(): ?array {
    \$files = glob(SESSIONS_PATH . '/*.json');
    if (!\$files) return null;
    \$candidates = [];
    foreach (\$files as \$f) {
        \$d = json_decode((string)file_get_contents(\$f), true);
        if (!is_array(\$d)) continue;
        if (in_array(\$d['status'] ?? '', ['waiting_signatures', 'signed_by_1'], true)) {
            \$candidates[] = \$d;
        }
    }
    if (!\$candidates) return null;
    usort(\$candidates, fn(\$a, \$b) => (\$b['sent_at'] ?? 0) <=> (\$a['sent_at'] ?? 0));
    return \$candidates[0];
}

function sanitize_name(string \$s): string {
    \$s = trim(\$s);
    \$s = preg_replace('/[^\p{L}\p{N}\s\-\'\.]/u', '', \$s);
    return mb_substr(\$s, 0, 50);
}

function cleanup_document_cache(string \$doc_id): void {
    \$doc_id = preg_replace('/[^a-f0-9]/', '', \$doc_id);
    if (strlen(\$doc_id) !== 32) return;
    \$pdf = PDF_PATH . '/' . \$doc_id . '.pdf';
    if (is_file(\$pdf)) @unlink(\$pdf);
    \$previewDir = PREVIEW_PATH . '/' . \$doc_id;
    if (is_dir(\$previewDir)) {
        foreach (glob(\$previewDir . '/*') as \$f) @unlink(\$f);
        @rmdir(\$previewDir);
    }
    foreach (['p1', 'p2'] as \$p) {
        \$sig = SIGNATURES_PATH . '/' . \$doc_id . '_' . \$p . '.png';
        if (is_file(\$sig)) @unlink(\$sig);
    }
}

function cleanup_storage(): array {
    \$stats = ['cache_cleaned' => 0, 'expired_deleted' => 0, 'drafts_deleted' => 0, 'orphans_deleted' => 0];
    \$now = time();
    \$TTL_FINAL = 30 * 24 * 3600;
    \$TTL_DRAFT = 24 * 3600;
    \$files = glob(SESSIONS_PATH . '/*.json');
    \$validIds = [];
    foreach (\$files as \$f) {
        \$doc = json_decode((string)file_get_contents(\$f), true);
        if (!is_array(\$doc) || empty(\$doc['doc_id'])) { @unlink(\$f); continue; }
        \$validIds[\$doc['doc_id']] = true;
        if (\$doc['status'] === 'draft' && (\$now - (\$doc['created_at'] ?? 0)) > \$TTL_DRAFT) {
            cleanup_document_cache(\$doc['doc_id']);
            if (!empty(\$doc['final_pdf'])) @unlink(FINAL_PATH . '/' . \$doc['final_pdf']);
            @unlink(\$f); \$stats['drafts_deleted']++; continue;
        }
        if (\$doc['status'] === 'completed' && (\$now - (\$doc['completed_at'] ?? 0)) > \$TTL_FINAL) {
            cleanup_document_cache(\$doc['doc_id']);
            if (!empty(\$doc['final_pdf'])) @unlink(FINAL_PATH . '/' . \$doc['final_pdf']);
            @unlink(\$f); \$stats['expired_deleted']++; continue;
        }
        if (\$doc['status'] === 'completed' && !empty(\$doc['downloaded_at']) && empty(\$doc['cache_cleaned'])) {
            cleanup_document_cache(\$doc['doc_id']);
            \$doc['cache_cleaned'] = true;
            save_document(\$doc['doc_id'], \$doc);
            \$stats['cache_cleaned']++;
        }
    }
    foreach (glob(PDF_PATH . '/*.pdf') as \$f) {
        \$id = pathinfo(\$f, PATHINFO_FILENAME);
        if (!isset(\$validIds[\$id])) { @unlink(\$f); \$stats['orphans_deleted']++; }
    }
    foreach (glob(PREVIEW_PATH . '/*', GLOB_ONLYDIR) as \$d) {
        \$id = basename(\$d);
        if (!isset(\$validIds[\$id])) {
            foreach (glob(\$d . '/*') as \$f) @unlink(\$f);
            @rmdir(\$d); \$stats['orphans_deleted']++;
        }
    }
    foreach (glob(SIGNATURES_PATH . '/*.png') as \$f) {
        \$id = preg_replace('/_p[12]\.png\$/', '', basename(\$f));
        if (!isset(\$validIds[\$id])) { @unlink(\$f); \$stats['orphans_deleted']++; }
    }
    foreach (glob(FINAL_PATH . '/*_signed.pdf') as \$f) {
        \$id = preg_replace('/_signed\.pdf\$/', '', basename(\$f));
        if (!isset(\$validIds[\$id])) { @unlink(\$f); \$stats['orphans_deleted']++; }
    }
    return \$stats;
}

function get_pending_documents_for_tablet(): array {
    \$files = glob(SESSIONS_PATH . '/*.json');
    if (!\$files) return [];
    \$list = [];
    foreach (\$files as \$f) {
        \$d = json_decode((string)file_get_contents(\$f), true);
        if (!is_array(\$d)) continue;
        if (in_array(\$d['status'] ?? '', ['waiting_signatures', 'signed_by_1'], true)) {
            \$list[] = [
                'doc_id' => \$d['doc_id'],
                'status' => \$d['status'],
                'p1_label' => \$d['p1_label'],
                'p2_label' => \$d['p2_label'],
                'original_filename' => \$d['original_filename'] ?? '',
                'sent_at' => \$d['sent_at'] ?? 0,
                'signed_1' => \$d['signed_1'],
                'signed_2' => \$d['signed_2'],
            ];
        }
    }
    usort(\$list, fn(\$a, \$b) => (\$b['sent_at'] ?? 0) <=> (\$a['sent_at'] ?? 0));
    return \$list;
}

function get_document_for_tablet(string \$doc_id): ?array {
    \$doc = load_document(\$doc_id);
    if (!\$doc) return null;
    if (!in_array(\$doc['status'], ['waiting_signatures', 'signed_by_1'], true)) return null;
    \$pages = array_map(fn(\$p) => [
        'num' => \$p['num'],
        'width' => \$p['width'],
        'height' => \$p['height'],
        'url' => '/api/preview.php?doc_id=' . \$doc['doc_id'] . '&page=' . \$p['num'],
    ], \$doc['pages']);
    return [
        'doc_id' => \$doc['doc_id'],
        'status' => \$doc['status'],
        'p1_label' => \$doc['p1_label'],
        'p2_label' => \$doc['p2_label'],
        'pages' => \$pages,
        'zones' => \$doc['zones'],
        'signed_1' => \$doc['signed_1'],
        'signed_2' => \$doc['signed_2'],
    ];
}

if (random_int(1, 20) === 1) { @cleanup_storage(); }
PHPEOF

# Remplacements placeholders
sed -i "s|__SECRET_KEY__|$SECRET_KEY|" "$INSTALL_PATH/config/config.php"
sed -i "s|__SESSION_PATH__|$INSTALL_PATH/storage/php_sessions|" "$INSTALL_PATH/config/config.php"
sed -i "s|__PC_USER__|$PC_USER|" "$INSTALL_PATH/config/config.php"
sed -i "s|__TAB_USER__|$TAB_USER|" "$INSTALL_PATH/config/config.php"
# Les hashs contiennent des / et $ — utiliser @ comme délimiteur et échapper
PC_HASH_ESC="${PC_HASH//@/\\@}"
TAB_HASH_ESC="${TAB_HASH//@/\\@}"
sed -i "s@__PC_HASH__@$PC_HASH_ESC@" "$INSTALL_PATH/config/config.php"
sed -i "s@__TAB_HASH__@$TAB_HASH_ESC@" "$INSTALL_PATH/config/config.php"

ok "config.php généré"

# ============================================================
# API : upload.php
# ============================================================
cat > "$INSTALL_PATH/api/upload.php" <<'PHPEOF'
<?php
set_time_limit(600);
ini_set('memory_limit', '1024M');

require_once __DIR__ . '/../config/config.php';
require_role('pc');

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    json_response(['success' => false, 'error' => 'Méthode non autorisée'], 405);
}
if (!verify_csrf_token($_POST['csrf_token'] ?? null)) {
    json_response(['success' => false, 'error' => 'CSRF invalide'], 403);
}

if (empty($_FILES['pdf']) || $_FILES['pdf']['error'] !== UPLOAD_ERR_OK) {
    json_response(['success' => false, 'error' => 'Aucun fichier reçu ou erreur upload'], 400);
}
$file = $_FILES['pdf'];
if ($file['size'] > MAX_PDF_SIZE) {
    json_response(['success' => false, 'error' => 'Fichier trop lourd (>10 Mo)'], 400);
}

$finfo = new finfo(FILEINFO_MIME_TYPE);
$mime = $finfo->file($file['tmp_name']);
if (!in_array($mime, ALLOWED_MIME, true)) {
    json_response(['success' => false, 'error' => 'Type MIME invalide (PDF requis)'], 400);
}

$fh = fopen($file['tmp_name'], 'rb');
$magic = fread($fh, 5);
fclose($fh);
if ($magic !== '%PDF-') {
    json_response(['success' => false, 'error' => 'Fichier PDF invalide'], 400);
}

$p1f = sanitize_name($_POST['p1_firstname'] ?? '');
$p1l = sanitize_name($_POST['p1_lastname'] ?? '');
$p2f = sanitize_name($_POST['p2_firstname'] ?? '');
$p2l = sanitize_name($_POST['p2_lastname'] ?? '');
if (!$p1f || !$p1l || !$p2f || !$p2l) {
    json_response(['success' => false, 'error' => 'Tous les noms sont requis'], 400);
}

$doc_id = bin2hex(random_bytes(16));
$pdf_dest = PDF_PATH . '/' . $doc_id . '.pdf';
if (!move_uploaded_file($file['tmp_name'], $pdf_dest)) {
    json_response(['success' => false, 'error' => 'Impossible de sauvegarder le PDF'], 500);
}
chmod($pdf_dest, 0644);

$preview_dir = PREVIEW_PATH . '/' . $doc_id;
if (!is_dir($preview_dir)) mkdir($preview_dir, 0755, true);

$pages = [];
$conversion_error = null;

$nbPages = 0;
$out = [];
exec('pdfinfo ' . escapeshellarg($pdf_dest) . ' 2>/dev/null', $out);
foreach ($out as $line) {
    if (preg_match('/^Pages:\s+(\d+)/', $line, $m)) {
        $nbPages = (int)$m[1];
        break;
    }
}

if ($nbPages < 1) {
    $conversion_error = 'Impossible de lire le nombre de pages (pdfinfo)';
} else {
    $cmd = sprintf(
        'gs -q -dNOPAUSE -dBATCH -dSAFER -sDEVICE=png16m -r120 -dTextAlphaBits=4 -dGraphicsAlphaBits=4 -sOutputFile=%s %s 2>&1',
        escapeshellarg($preview_dir . '/page_%d.png'),
        escapeshellarg($pdf_dest)
    );
    $gs_out = [];
    $gs_rc = 0;
    exec($cmd, $gs_out, $gs_rc);

    if ($gs_rc !== 0) {
        $conversion_error = 'Ghostscript rc=' . $gs_rc . ' : ' . implode(' | ', $gs_out);
    } else {
        for ($pageNum = 1; $pageNum <= $nbPages; $pageNum++) {
            $outFile = $preview_dir . '/page_' . $pageNum . '.png';
            if (!is_file($outFile)) {
                $conversion_error = 'Page ' . $pageNum . ' non générée';
                $pages = [];
                break;
            }
            chmod($outFile, 0644);
            $info = getimagesize($outFile);
            $pages[] = [
                'num'    => $pageNum,
                'width'  => $info[0],
                'height' => $info[1],
                'url'    => '/api/preview.php?doc_id=' . $doc_id . '&page=' . $pageNum,
            ];
        }
    }
}

if (empty($pages)) {
    @unlink($pdf_dest);
    json_response([
        'success' => false,
        'error' => 'Impossible de convertir le PDF en images. ' . ($conversion_error ?? '') .
                   ' — Vérifiez que pdfinfo et Ghostscript sont installés.'
    ], 500);
}

$doc_data = [
    'doc_id' => $doc_id,
    'created_at' => time(),
    'created_by' => $_SESSION['user']['username'],
    'status' => 'draft',
    'original_filename' => basename($file['name']),
    'p1_firstname' => $p1f,
    'p1_lastname' => $p1l,
    'p1_label' => $p1f . ' ' . $p1l,
    'p2_firstname' => $p2f,
    'p2_lastname' => $p2l,
    'p2_label' => $p2f . ' ' . $p2l,
    'pages' => array_map(fn($p) => ['num' => $p['num'], 'width' => $p['width'], 'height' => $p['height']], $pages),
    'zones' => [],
    'signed_1' => false,
    'signed_2' => false,
    'signature_1_file' => null,
    'signature_2_file' => null,
    'final_pdf' => null,
    'sent_at' => null,
    'completed_at' => null,
];
save_document($doc_id, $doc_data);

json_response([
    'success' => true,
    'doc_id' => $doc_id,
    'pages' => $pages,
    'p1_label' => $doc_data['p1_label'],
    'p2_label' => $doc_data['p2_label'],
]);
PHPEOF

# ============================================================
# API : preview.php
# ============================================================
cat > "$INSTALL_PATH/api/preview.php" <<'PHPEOF'
<?php
require_once __DIR__ . '/../config/config.php';

if (empty($_SESSION['user'])) { http_response_code(403); exit; }

$doc_id = preg_replace('/[^a-f0-9]/', '', $_GET['doc_id'] ?? '');
$page = (int)($_GET['page'] ?? 0);

if (strlen($doc_id) !== 32 || $page < 1 || $page > 200) {
    http_response_code(400); exit;
}

$file = PREVIEW_PATH . '/' . $doc_id . '/page_' . $page . '.png';
if (!is_file($file)) { http_response_code(404); exit; }

header('Content-Type: image/png');
header('Cache-Control: private, max-age=3600');
header('Content-Length: ' . filesize($file));
readfile($file);
exit;
PHPEOF

# ============================================================
# API : set_zones.php
# ============================================================
cat > "$INSTALL_PATH/api/set_zones.php" <<'PHPEOF'
<?php
require_once __DIR__ . '/../config/config.php';
require_role('pc');

$input = json_decode(file_get_contents('php://input'), true);
if (!is_array($input)) json_response(['success' => false, 'error' => 'JSON invalide'], 400);
if (!verify_csrf_token($input['csrf_token'] ?? null)) {
    json_response(['success' => false, 'error' => 'CSRF invalide'], 403);
}

$doc_id = $input['doc_id'] ?? '';
$zones = $input['zones'] ?? [];
if (!is_array($zones) || count($zones) < 1 || count($zones) > 20) {
    json_response(['success' => false, 'error' => 'Zones invalides'], 400);
}

$doc = load_document($doc_id);
if (!$doc) json_response(['success' => false, 'error' => 'Document introuvable'], 404);
if ($doc['status'] !== 'draft') json_response(['success' => false, 'error' => 'Document déjà envoyé'], 400);

$clean = [];
$persons = [];
foreach ($zones as $z) {
    $person = (int)($z['person'] ?? 0);
    $page = (int)($z['page'] ?? 0);
    $rx = (float)($z['rel_x'] ?? -1);
    $ry = (float)($z['rel_y'] ?? -1);
    $rw = (float)($z['rel_w'] ?? 0);
    $rh = (float)($z['rel_h'] ?? 0);

    if (!in_array($person, [1, 2], true)) continue;
    if ($page < 1 || $page > count($doc['pages'])) continue;
    if ($rx < 0 || $rx > 1 || $ry < 0 || $ry > 1) continue;
    if ($rw <= 0 || $rw > 1 || $rh <= 0 || $rh > 1) continue;

    $label = $person === 1 ? $doc['p1_label'] : $doc['p2_label'];
    $clean[] = [
        'person' => $person,
        'page' => $page,
        'rel_x' => $rx,
        'rel_y' => $ry,
        'rel_w' => $rw,
        'rel_h' => $rh,
        'label' => $label,
    ];
    $persons[$person] = true;
}

if (!isset($persons[1]) || !isset($persons[2])) {
    json_response(['success' => false, 'error' => 'Il faut une zone pour chaque personne'], 400);
}

$doc['zones'] = $clean;
$doc['status'] = 'zones_placed';
save_document($doc_id, $doc);

json_response(['success' => true]);
PHPEOF

# ============================================================
# API : send_to_tablet.php
# ============================================================
cat > "$INSTALL_PATH/api/send_to_tablet.php" <<'PHPEOF'
<?php
require_once __DIR__ . '/../config/config.php';
require_role('pc');

$input = json_decode(file_get_contents('php://input'), true);
if (!is_array($input)) json_response(['success' => false, 'error' => 'JSON invalide'], 400);
if (!verify_csrf_token($input['csrf_token'] ?? null)) {
    json_response(['success' => false, 'error' => 'CSRF invalide'], 403);
}

$doc_id = $input['doc_id'] ?? '';
$doc = load_document($doc_id);
if (!$doc) json_response(['success' => false, 'error' => 'Document introuvable'], 404);
if ($doc['status'] !== 'zones_placed') {
    json_response(['success' => false, 'error' => 'État document incorrect'], 400);
}
if (empty($doc['zones'])) {
    json_response(['success' => false, 'error' => 'Aucune zone définie'], 400);
}

$doc['status'] = 'waiting_signatures';
$doc['sent_at'] = time();
save_document($doc_id, $doc);

json_response(['success' => true]);
PHPEOF

# ============================================================
# API : status.php
# ============================================================
cat > "$INSTALL_PATH/api/status.php" <<'PHPEOF'
<?php
require_once __DIR__ . '/../config/config.php';

if (empty($_SESSION['user'])) {
    json_response(['success' => false, 'error' => 'Non authentifié'], 403);
}
$role = $_SESSION['user']['role'];

if ($role === 'tablet') {
    if (!empty($_GET['list'])) {
        json_response([
            'success' => true,
            'documents' => get_pending_documents_for_tablet(),
        ]);
    }
    if (!empty($_GET['doc_id'])) {
        $doc = get_document_for_tablet($_GET['doc_id']);
        if (!$doc) json_response(['success' => true, 'document' => null]);
        json_response(['success' => true, 'document' => $doc]);
    }
    json_response(['success' => false, 'error' => 'Paramètres manquants'], 400);
}

$doc_id = $_GET['doc_id'] ?? '';
$doc = load_document($doc_id);
if (!$doc) json_response(['success' => false, 'error' => 'Document introuvable'], 404);

json_response([
    'success' => true,
    'doc_id' => $doc['doc_id'],
    'status' => $doc['status'],
    'signed_1' => $doc['signed_1'],
    'signed_2' => $doc['signed_2'],
    'p1_label' => $doc['p1_label'],
    'p2_label' => $doc['p2_label'],
    'original_filename' => $doc['original_filename'] ?? '',
]);
PHPEOF

# ============================================================
# API : sign.php
# ============================================================
cat > "$INSTALL_PATH/api/sign.php" <<'PHPEOF'
<?php
require_once __DIR__ . '/../config/config.php';
require_role('tablet');

$input = json_decode(file_get_contents('php://input'), true);
if (!is_array($input)) json_response(['success' => false, 'error' => 'JSON invalide'], 400);
if (!verify_csrf_token($input['csrf_token'] ?? null)) {
    json_response(['success' => false, 'error' => 'CSRF invalide'], 403);
}

$doc_id = $input['doc_id'] ?? '';
$person = (int)($input['person'] ?? 0);
$b64 = $input['signature'] ?? '';

if (!in_array($person, [1, 2], true)) {
    json_response(['success' => false, 'error' => 'Personne invalide'], 400);
}

$doc = load_document($doc_id);
if (!$doc) json_response(['success' => false, 'error' => 'Document introuvable'], 404);
if (!in_array($doc['status'], ['waiting_signatures', 'signed_by_1'], true)) {
    json_response(['success' => false, 'error' => 'Document non signable'], 400);
}

if (!preg_match('/^data:image\/png;base64,([A-Za-z0-9+\/=]+)$/', $b64, $m)) {
    json_response(['success' => false, 'error' => 'Signature invalide'], 400);
}
$bin = base64_decode($m[1], true);
if ($bin === false || strlen($bin) < 100 || strlen($bin) > 2 * 1024 * 1024) {
    json_response(['success' => false, 'error' => 'Données signature invalides'], 400);
}
if (substr($bin, 0, 8) !== "\x89PNG\r\n\x1a\n") {
    json_response(['success' => false, 'error' => 'Format PNG invalide'], 400);
}

$sig_file = SIGNATURES_PATH . '/' . $doc_id . '_p' . $person . '.png';
if (file_put_contents($sig_file, $bin) === false) {
    json_response(['success' => false, 'error' => 'Erreur sauvegarde signature'], 500);
}
chmod($sig_file, 0644);

if ($person === 1) {
    if ($doc['signed_1']) json_response(['success' => false, 'error' => 'Personne 1 déjà signée'], 400);
    $doc['signed_1'] = true;
    $doc['signature_1_file'] = basename($sig_file);
    $doc['signed_1_at'] = time();
} else {
    if ($doc['signed_2']) json_response(['success' => false, 'error' => 'Personne 2 déjà signée'], 400);
    $doc['signed_2'] = true;
    $doc['signature_2_file'] = basename($sig_file);
    $doc['signed_2_at'] = time();
}

if ($doc['signed_1'] && $doc['signed_2']) {
    $final = generate_final_pdf($doc);
    if (!$final) {
        json_response(['success' => false, 'error' => 'Erreur génération PDF final'], 500);
    }
    $doc['final_pdf'] = basename($final);
    $doc['status'] = 'completed';
    $doc['completed_at'] = time();
} elseif ($doc['signed_1']) {
    $doc['status'] = 'signed_by_1';
} elseif ($doc['signed_2']) {
    $doc['status'] = 'signed_by_1';
}

save_document($doc_id, $doc);
json_response(['success' => true, 'status' => $doc['status']]);


function generate_final_pdf(array $doc): ?string {
    require_once LIBS_PATH . '/tcpdf/tcpdf.php';
    require_once LIBS_PATH . '/FPDI/src/autoload.php';

    try {
        $pdf = new \setasign\Fpdi\Tcpdf\Fpdi();
        $pdf->setPrintHeader(false);
        $pdf->setPrintFooter(false);
        $pdf->SetAutoPageBreak(false);
        $pdf->SetMargins(0, 0, 0);

        $src_pdf = PDF_PATH . '/' . $doc['doc_id'] . '.pdf';

        $compat_pdf = sys_get_temp_dir() . '/fpdi_' . $doc['doc_id'] . '.pdf';
        $cmd = sprintf(
            'gs -q -dNOPAUSE -dBATCH -dSAFER -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 -sOutputFile=%s %s 2>&1',
            escapeshellarg($compat_pdf),
            escapeshellarg($src_pdf)
        );
        exec($cmd, $out, $rc);
        if ($rc !== 0 || !is_file($compat_pdf)) {
            error_log('GS decompress failed: ' . implode("\n", $out));
            $compat_pdf = $src_pdf;
        }

        $pageCount = $pdf->setSourceFile($compat_pdf);

        for ($pageNo = 1; $pageNo <= $pageCount; $pageNo++) {
            $tplId = $pdf->importPage($pageNo);
            $size = $pdf->getTemplateSize($tplId);
            $orientation = ($size['width'] > $size['height']) ? 'L' : 'P';
            $pdf->AddPage($orientation, [$size['width'], $size['height']]);
            $pdf->useTemplate($tplId, 0, 0, $size['width'], $size['height']);

            foreach ($doc['zones'] as $zone) {
                if ((int)$zone['page'] !== $pageNo) continue;

                $sigFile = null;
                if ((int)$zone['person'] === 1 && !empty($doc['signature_1_file'])) {
                    $sigFile = SIGNATURES_PATH . '/' . $doc['signature_1_file'];
                } elseif ((int)$zone['person'] === 2 && !empty($doc['signature_2_file'])) {
                    $sigFile = SIGNATURES_PATH . '/' . $doc['signature_2_file'];
                }
                if (!$sigFile || !is_file($sigFile)) continue;

                $zx = $zone['rel_x'] * $size['width'];
                $zy = $zone['rel_y'] * $size['height'];
                $zw = $zone['rel_w'] * $size['width'];
                $zh = $zone['rel_h'] * $size['height'];

                $pdf->Image($sigFile, $zx, $zy, $zw, $zh, 'PNG', '', '', false, 300, '', false, false, 0);

                $pdf->SetFont('helvetica', '', 7);
                $pdf->SetTextColor(60, 60, 60);
                $pdf->SetXY($zx, $zy + $zh);
                $pdf->Cell($zw, 3, 'Signé : ' . $zone['label'], 0, 0, 'C');
            }
        }

        $outFile = FINAL_PATH . '/' . $doc['doc_id'] . '_signed.pdf';
        $pdf->Output($outFile, 'F');
        chmod($outFile, 0644);
        if ($compat_pdf !== $src_pdf && is_file($compat_pdf)) @unlink($compat_pdf);
        return $outFile;
    } catch (\Throwable $e) {
        error_log("SIGN PDF ERROR: " . $e->getMessage() . " @ " . $e->getFile() . ":" . $e->getLine() . "\n" . $e->getTraceAsString());
        return null;
    }
}
PHPEOF

# ============================================================
# API : download.php
# ============================================================
cat > "$INSTALL_PATH/api/download.php" <<'PHPEOF'
<?php
require_once __DIR__ . '/../config/config.php';
require_role('pc');

$doc_id = preg_replace('/[^a-f0-9]/', '', $_GET['doc_id'] ?? '');
if (strlen($doc_id) !== 32) {
    http_response_code(400); echo 'Paramètre invalide'; exit;
}

$doc = load_document($doc_id);
if (!$doc) { http_response_code(404); echo 'Document introuvable'; exit; }
if ($doc['status'] !== 'completed' || empty($doc['final_pdf'])) {
    http_response_code(400); echo 'Document non finalisé'; exit;
}

$file = FINAL_PATH . '/' . $doc['final_pdf'];
if (!is_file($file)) { http_response_code(404); echo 'Fichier introuvable'; exit; }

if (empty($doc['downloaded_at'])) {
    $doc['downloaded_at'] = time();
    save_document($doc_id, $doc);
}

$filename = 'signe_' . preg_replace('/[^A-Za-z0-9_\-]/', '_', pathinfo($doc['original_filename'], PATHINFO_FILENAME)) . '.pdf';

header('Content-Type: application/pdf');
header('Content-Disposition: attachment; filename="' . $filename . '"');
header('Content-Length: ' . filesize($file));
header('Cache-Control: private, no-cache');
header('X-Content-Type-Options: nosniff');
readfile($file);
exit;
PHPEOF

ok "API générée (7 fichiers)"

# ============================================================
# CSS : style.css
# ============================================================
cat > "$INSTALL_PATH/assets/css/style.css" <<'CSSEOF'
* { box-sizing: border-box; }
body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
    margin: 0; padding: 0; background: #f6f8fa; color: #24292f;
    font-size: 15px; line-height: 1.5;
}
h1, h2, h3 { color: #24292f; }
.btn {
    display: inline-block; padding: 10px 18px; font-size: 15px; font-weight: 600;
    border: none; border-radius: 6px; cursor: pointer; text-decoration: none;
    transition: background-color 0.15s; font-family: inherit;
}
.btn-primary { background: #0969da; color: white; }
.btn-primary:hover:not(:disabled) { background: #0550ae; }
.btn-primary:disabled { background: #a0b4cc; cursor: not-allowed; }
.btn-success { background: #1a7f37; color: white; }
.btn-success:hover { background: #116329; }
.btn-ghost { background: #f6f8fa; color: #24292f; border: 1px solid #d0d7de; }
.btn-ghost:hover { background: #eaeef2; }
.top-bar {
    display: flex; justify-content: space-between; align-items: center;
    padding: 14px 24px; background: #24292f; color: white;
}
.top-bar h1 { margin: 0; font-size: 18px; color: white; }
.user-info { display: flex; align-items: center; gap: 14px; font-size: 14px; }
.user-info .btn { padding: 6px 14px; font-size: 13px; }
.alert { padding: 12px 16px; border-radius: 6px; margin: 12px 0; font-size: 14px; }
.alert-error { background: #ffebe9; color: #82071e; border: 1px solid #ffcecb; }
.alert-warning { background: #fff8c5; color: #7d4e00; border: 1px solid #eac54f; }
.alert-success { background: #dafbe1; color: #116329; border: 1px solid #aceebb; }
.status-msg { margin-top: 10px; font-size: 14px; min-height: 20px; }
.status-msg.info { color: #0969da; }
.status-msg.success { color: #1a7f37; }
.status-msg.error { color: #cf222e; }
.login-body {
    min-height: 100vh; display: flex; align-items: center; justify-content: center;
    background: linear-gradient(135deg, #0969da 0%, #24292f 100%);
}
.login-box {
    background: white; padding: 40px; border-radius: 10px;
    box-shadow: 0 8px 24px rgba(0,0,0,0.15); width: 100%; max-width: 400px;
}
.login-box h1 { margin: 0 0 6px; font-size: 24px; text-align: center; }
.login-box .subtitle { margin: 0 0 24px; text-align: center; color: #57606a; }
.login-box label { display: block; margin-bottom: 14px; font-weight: 600; font-size: 14px; }
.login-box input {
    width: 100%; padding: 10px 12px; margin-top: 6px;
    border: 1px solid #d0d7de; border-radius: 6px; font-size: 15px; box-sizing: border-box;
}
.login-box input:focus { outline: none; border-color: #0969da; box-shadow: 0 0 0 3px rgba(9,105,218,0.2); }
.login-box .btn { width: 100%; margin-top: 10px; padding: 12px; font-size: 16px; }
.help { color: #57606a; font-size: 14px; }
.hidden { display: none !important; }
CSSEOF

# ============================================================
# CSS : pc.css
# ============================================================
cat > " $INSTALL_PATH/assets/css/pc.css" <<'CSSEOF'
.container { max-width: 1200px; margin: 20px auto; padding: 0 20px; }
.card {
    background: #fff; border-radius: 8px; padding: 24px; margin-bottom: 20px;
    box-shadow: 0 2px 8px rgba(0,0,0,0.06);
}
.card h2 { margin-top: 0; color: #2c3e50; }
.hidden { display: none !important; }
.form-row { margin: 16px 0; }
.form-row label { display: block; font-weight: 600; margin-bottom: 6px; }
.form-row-double { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin: 16px 0; }
fieldset { border: 1px solid #d0d7de; padding: 12px 16px; border-radius: 6px; }
fieldset legend { font-weight: 700; padding: 0 6px; color: #0969da; }
fieldset label { display: block; margin: 8px 0; font-size: 14px; }
fieldset input { width: 100%; padding: 8px; border: 1px solid #d0d7de; border-radius: 4px; box-sizing: border-box; }
input[type="file"] { padding: 8px; border: 1px dashed #d0d7de; background: #f6f8fa; border-radius: 4px; }
.person-selector { display: flex; gap: 12px; margin-bottom: 16px; }
.person-btn {
    padding: 10px 18px; border: 2px solid #d0d7de; background: #fff;
    cursor: pointer; border-radius: 6px; font-weight: 600;
}
.person-btn.active { border-color: #0969da; background: #ddf4ff; color: #0969da; }
.pdf-pages { display: flex; flex-direction: column; gap: 24px; }
.pdf-page-wrap { border: 1px solid #d0d7de; border-radius: 6px; overflow: hidden; background: #f6f8fa; }
.page-title { padding: 6px 12px; background: #eaeef2; font-size: 13px; color: #57606a; font-weight: 600; }
.pdf-page { position: relative; background: #fff; cursor: crosshair; }
.sig-zone {
    border: 3px dashed #0969da; background: rgba(9,105,218,0.15); color: #0969da;
    font-weight: 700; font-size: 13px; display: flex; align-items: center; justify-content: center;
    text-align: center; padding: 4px; box-sizing: border-box; pointer-events: none; border-radius: 4px;
}
.sig-zone-p2 { border-color: #bf8700; background: rgba(191,135,0,0.15); color: #bf8700; }
.actions-row { display: flex; gap: 12px; justify-content: flex-end; margin-top: 20px; }
.tracking-box { padding: 16px 0; }
.status-indicator { padding: 16px; border-radius: 6px; font-size: 18px; font-weight: 600; text-align: center; margin-bottom: 20px; }
.status-indicator.waiting { background: #fff8c5; color: #7d4e00; }
.status-indicator.pending { background: #ffe4a3; color: #7d4e00; }
.status-indicator.success { background: #dafbe1; color: #116329; }
.signatures-progress { display: flex; flex-direction: column; gap: 10px; margin-bottom: 20px; }
.sig-item { display: flex; align-items: center; gap: 12px; padding: 12px 16px; background: #f6f8fa; border-radius: 6px; }
.sig-dot { width: 16px; height: 16px; border-radius: 50%; background: #d0d7de; flex-shrink: 0; }
.sig-item.signed .sig-dot { background: #1a7f37; }
.sig-item.signed { background: #dafbe1; }
.sig-name { flex: 1; font-weight: 600; }
.sig-state { font-size: 14px; color: #57606a; }
.sig-item.signed .sig-state { color: #116329; font-weight: 700; }
.tracking-list { display: flex; flex-direction: column; gap: 16px; }
.tracked-doc {
    background: #fff; border: 2px solid #d0d7de; border-radius: 8px;
    padding: 16px 20px; transition: border-color 0.2s;
}
.tracked-doc.success { border-color: #1a7f37; background: #f0fff4; }
.tracked-doc.pending { border-color: #bf8700; background: #fffbeb; }
.tracked-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; flex-wrap: wrap; gap: 10px; }
.tracked-title { font-weight: 700; font-size: 16px; color: #24292f; }
.tracked-status { padding: 4px 12px; border-radius: 12px; font-size: 13px; font-weight: 600; }
.status-waiting { background: #fff8c5; color: #7d4e00; }
.status-pending { background: #ffe4a3; color: #7d4e00; }
.status-success { background: #dafbe1; color: #116329; }
.tracked-signers { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-bottom: 12px; }
.btn-dl { width: 100%; margin-top: 8px; }
CSSEOF

# ============================================================
# CSS : tablet.css
# ============================================================
cat > "$INSTALL_PATH/assets/css/tablet.css" <<'CSSEOF'
.tablet-body {
    background: #f4f1ea; margin: 0; padding: 0; overflow-x: hidden;
    user-select: none; -webkit-user-select: none;
    -webkit-tap-highlight-color: transparent; touch-action: manipulation;
}
.fullscreen-center {
    position: fixed; top: 0; left: 0; right: 0; bottom: 0;
    display: flex; flex-direction: column; align-items: center; justify-content: center;
    text-align: center; background: #f4f1ea; padding: 40px;
}
.fullscreen-center h1 { font-size: 32px; color: #2c3e50; margin: 20px 0 10px; }
.fullscreen-center p { font-size: 20px; color: #57606a; }
.big-icon { font-size: 90px; line-height: 1; }
.big-icon.success { color: #1a7f37; }
.tablet-header {
    padding: 16px 24px; background: #fff; border-bottom: 2px solid #d0d7de;
    position: sticky; top: 0; z-index: 10;
    display: flex; align-items: center; flex-wrap: wrap; gap: 10px;
}
.tablet-header h2 { margin: 0 0 10px 0; font-size: 20px; color: #2c3e50; flex: 1; min-width: 200px; }
.signer-banner {
    padding: 12px 20px; border-radius: 6px; font-size: 22px; font-weight: 700; text-align: center;
}
.signer-banner.person-1 { background: #ddf4ff; color: #0969da; border: 2px solid #0969da; }
.signer-banner.person-2 { background: #fff4d6; color: #bf8700; border: 2px solid #bf8700; }
#doc-content { padding: 20px; }
.tablet-page-wrap {
    max-width: 900px; margin: 0 auto 20px; border: 1px solid #d0d7de;
    border-radius: 6px; overflow: hidden; background: #fff;
}
.tablet-page { position: relative; }
.tablet-page img { display: block; width: 100%; height: auto; }
.tablet-sig-zone {
    position: absolute; border: 3px dashed #0969da; background: rgba(9,105,218,0.12);
    color: #0969da; font-weight: 700; font-size: 15px;
    display: flex; align-items: center; justify-content: center; text-align: center;
    padding: 4px; box-sizing: border-box; border-radius: 4px; pointer-events: none;
}
.tablet-sig-zone.sig-zone-p2 { border-color: #bf8700; background: rgba(191,135,0,0.12); color: #bf8700; }
.tablet-sig-zone.signed {
    background: rgba(26,127,55,0.18) !important;
    border-color: #1a7f37 !important; color: #116329 !important;
}
.signature-panel {
    position: sticky; bottom: 0; background: #fff; border-top: 3px solid #0969da;
    box-shadow: 0 -4px 16px rgba(0,0,0,0.1); padding: 16px 20px 20px;
    margin: 20px -20px -20px; z-index: 5;
}
.signature-header h3 { margin: 0 0 12px; font-size: 20px; color: #2c3e50; text-align: center; }
#signature-canvas {
    display: block;
    width: 100%;
    height: 55vh;
    max-height: 600px;
    margin: 0 auto;
    border: 2px solid #0969da;
    background: #fffdf5;
    border-radius: 6px;
    touch-action: none;
    box-sizing: border-box;
}
.signature-actions { display: flex; gap: 20px; margin-top: 16px; justify-content: center; }
.btn-big {
    min-height: 60px; min-width: 180px; font-size: 18px; font-weight: 700;
    padding: 0 28px; border-radius: 8px; border: none; cursor: pointer;
}
.btn-big.btn-primary { background: #0969da; color: white; }
.btn-big.btn-ghost { background: #eaeef2; color: #24292f; border: 2px solid #d0d7de; }
.btn-big:disabled { opacity: 0.5; }
.list-screen { min-height: 100vh; padding: 24px; background: #f4f1ea; }
.list-header { text-align: center; margin-bottom: 28px; padding-bottom: 20px; border-bottom: 2px solid #d0d7de; }
.list-header h1 { font-size: 32px; color: #2c3e50; margin-bottom: 8px; }
.list-count { font-size: 18px; color: #57606a; }
.list-count span { font-weight: 700; color: #0969da; }
.documents-list { max-width: 900px; margin: 0 auto; display: flex; flex-direction: column; gap: 16px; }
.doc-card {
    background: #fff; border: 2px solid #d0d7de; border-radius: 12px;
    padding: 20px; cursor: pointer; transition: all 0.15s; min-height: 110px;
}
.doc-card:active { transform: scale(0.98); border-color: #0969da; box-shadow: 0 4px 12px rgba(9,105,218,0.2); }
.doc-card-header { display: flex; align-items: center; gap: 14px; margin-bottom: 12px; }
.doc-card-icon { font-size: 36px; }
.doc-card-title { flex: 1; min-width: 0; }
.doc-filename { font-size: 18px; font-weight: 700; color: #2c3e50; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.doc-date { font-size: 13px; color: #7d8590; margin-top: 2px; }
.doc-signers { display: flex; gap: 10px; flex-wrap: wrap; margin-bottom: 12px; }
.signer-chip {
    padding: 6px 14px; background: #fff4d6; border: 1px solid #eac54f;
    border-radius: 20px; font-size: 14px; font-weight: 600; color: #7d4e00;
}
.signer-chip.done { background: #dafbe1; border-color: #1a7f37; color: #116329; }
.doc-action { display: flex; justify-content: space-between; align-items: center; padding-top: 10px; border-top: 1px solid #eaeef2; }
.doc-progress { font-size: 14px; color: #57606a; }
.doc-arrow { font-size: 24px; color: #0969da; font-weight: 700; }
.empty-state { text-align: center; padding: 60px 20px; }
.empty-state h2 { font-size: 26px; color: #2c3e50; margin: 16px 0 8px; }
.empty-state p { color: #57606a; font-size: 16px; }
.btn-back { margin-right: 16px; font-size: 16px; padding: 8px 14px; }
.toast {
    position: fixed; bottom: 30px; left: 50%; transform: translateX(-50%);
    background: #116329; color: white; padding: 16px 28px; border-radius: 30px;
    box-shadow: 0 6px 20px rgba(0,0,0,0.25);
    display: flex; align-items: center; gap: 12px;
    font-size: 18px; font-weight: 600; z-index: 1000;
    animation: slideUp 0.3s ease;
}
.toast.error { background: #82071e; }
.toast-icon { font-size: 24px; }
@keyframes slideUp {
    from { transform: translate(-50%, 100px); opacity: 0; }
    to { transform: translate(-50%, 0); opacity: 1; }
}
.reading-screen { display: flex; flex-direction: column; height: 100vh; background: #1a1a1a; }
.reading-header {
    display: flex; align-items: center; justify-content: space-between;
    padding: 12px 20px; background: #2a2a2a; color: #fff;
    border-bottom: 1px solid #444; flex-shrink: 0;
}
.reading-header h2 {
    margin: 0; font-size: 18px; flex: 1; text-align: center;
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis; padding: 0 16px;
}
.page-indicator { font-size: 14px; color: #bbb; min-width: 80px; text-align: right; }
.reading-viewport {
    flex: 1; overflow: auto; display: flex; align-items: center; justify-content: center;
    padding: 16px; background: #333; touch-action: pinch-zoom;
}
.reading-page-wrapper { transform-origin: center center; transition: transform 0.15s ease; }
.reading-page-wrapper img {
    max-width: 100%; max-height: calc(100vh - 180px); display: block;
    box-shadow: 0 4px 20px rgba(0,0,0,0.5); background: #fff;
    user-select: none; -webkit-user-drag: none;
}
.reading-footer {
    display: flex; align-items: center; justify-content: space-between; gap: 12px;
    padding: 12px 20px; background: #2a2a2a; border-top: 1px solid #444; flex-shrink: 0;
}
.reading-footer .btn { min-width: 120px; }
.reading-footer .btn-sign {
    background: #2e7d32; color: #fff; font-size: 18px; padding: 14px 32px; flex: 1; max-width: 320px;
}
.reading-footer .btn-sign:hover:not(:disabled) { background: #1b5e20; }
.reading-footer .btn-nav { background: #555; color: #fff; }
.reading-footer .btn-nav:disabled { background: #333; color: #666; cursor: not-allowed; }
.zoom-controls { display: flex; gap: 6px; margin-left: 12px; }
.zoom-controls .btn { min-width: 44px; padding: 8px 10px; background: #444; color: #fff; }
CSSEOF

ok "CSS générés (3 fichiers)"

# ============================================================
# JS : signature_canvas.js
# ============================================================
cat > "$INSTALL_PATH/assets/js/signature_canvas.js" <<'JSEOF'
window.SignatureCanvas = (function() {
    'use strict';
    window.APP_CSRF = document.querySelector('meta[name="csrf-token"]').content;

    function create(canvas) {
        const ctx = canvas.getContext('2d');
        let drawing = false;
        let hasContent = false;
        let lastX = 0, lastY = 0;

        function resize() {
            const prev = hasContent ? canvas.toDataURL() : null;
            const rect = canvas.getBoundingClientRect();
            let cssW = rect.width;
            let cssH = rect.height;
            if (cssW < 10) cssW = canvas.parentElement.clientWidth - 20;
            if (cssH < 10) cssH = cssW * (250 / 800);
            const dpr = window.devicePixelRatio || 1;
            canvas.style.width = cssW + 'px';
            canvas.style.height = cssH + 'px';
            canvas.width = Math.round(cssW * dpr);
            canvas.height = Math.round(cssH * dpr);
            ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
            ctx.fillStyle = '#fffdf5';
            ctx.fillRect(0, 0, cssW, cssH);
            ctx.strokeStyle = '#111';
            ctx.lineWidth = 2.5;
            ctx.lineCap = 'round';
            ctx.lineJoin = 'round';
            if (prev) {
                const img = new Image();
                img.onload = () => ctx.drawImage(img, 0, 0, cssW, cssH);
                img.src = prev;
            }
        }

        function getPos(e) {
            const rect = canvas.getBoundingClientRect();
            const clientX = e.touches ? e.touches[0].clientX : e.clientX;
            const clientY = e.touches ? e.touches[0].clientY : e.clientY;
            return { x: clientX - rect.left, y: clientY - rect.top };
        }

        function start(e) { e.preventDefault(); drawing = true; const p = getPos(e); lastX = p.x; lastY = p.y; }
        function move(e) {
            if (!drawing) return;
            e.preventDefault();
            const p = getPos(e);
            ctx.beginPath(); ctx.moveTo(lastX, lastY); ctx.lineTo(p.x, p.y); ctx.stroke();
            lastX = p.x; lastY = p.y; hasContent = true;
        }
        function end(e) { if (e) e.preventDefault(); drawing = false; }

        canvas.addEventListener('mousedown', start);
        canvas.addEventListener('mousemove', move);
        canvas.addEventListener('mouseup', end);
        canvas.addEventListener('mouseleave', end);
        canvas.addEventListener('touchstart', start, { passive: false });
        canvas.addEventListener('touchmove', move, { passive: false });
        canvas.addEventListener('touchend', end, { passive: false });

        resize();
        window.addEventListener('resize', resize);

        return {
            clear() {
                const dpr = window.devicePixelRatio || 1;
                const cssW = canvas.width / dpr;
                const cssH = canvas.height / dpr;
                ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
                ctx.fillStyle = '#fffdf5';
                ctx.fillRect(0, 0, cssW, cssH);
                ctx.strokeStyle = '#111'; ctx.lineWidth = 2.5;
                ctx.lineCap = 'round'; ctx.lineJoin = 'round';
                hasContent = false;
            },
            resize,
            isEmpty() { return !hasContent; },
            toBase64() {
                const tmp = document.createElement('canvas');
                tmp.width = canvas.width; tmp.height = canvas.height;
                const tctx = tmp.getContext('2d');
                const src = ctx.getImageData(0, 0, canvas.width, canvas.height);
                for (let i = 0; i < src.data.length; i += 4) {
                    const r = src.data[i], g = src.data[i+1], b = src.data[i+2];
                    if (r > 240 && g > 235 && b > 220) { src.data[i+3] = 0; }
                }
                tctx.putImageData(src, 0, 0);
                return tmp.toDataURL('image/png');
            },
            disable() { canvas.style.pointerEvents = 'none'; canvas.style.opacity = '0.6'; },
        };
    }
    return { create };
})();
JSEOF

# ============================================================
# JS : pc.js
# ============================================================
cat > "$INSTALL_PATH/assets/js/pc.js" <<'JSEOF'
(function() {
    'use strict';
    window.APP_CSRF = document.querySelector('meta[name="csrf-token"]').content;

    const state = {
        docId: null, pages: [], zones: [], activePerson: 1,
        personLabels: {}, trackedDocs: {}, pollTimer: null,
    };
    const ZONE_W = 200, ZONE_H = 70;

    const uploadForm = document.getElementById('upload-form');
    const uploadStatus = document.getElementById('upload-status');

    uploadForm.addEventListener('submit', async (e) => {
        e.preventDefault();
        uploadStatus.textContent = 'Chargement en cours…';
        uploadStatus.className = 'status-msg info';
        const fd = new FormData(uploadForm);
        try {
            const r = await fetch('/api/upload.php', { method: 'POST', body: fd });
            const data = await r.json();
            if (!data.success) throw new Error(data.error || 'Erreur upload');

            state.docId = data.doc_id;
            state.pages = data.pages;
            state.zones = [];
            state.activePerson = 1;
            state.personLabels[1] = data.p1_label;
            state.personLabels[2] = data.p2_label;

            document.getElementById('label-p1').textContent = data.p1_label;
            document.getElementById('label-p2').textContent = data.p2_label;

            document.querySelectorAll('.person-btn').forEach(b => b.classList.remove('active'));
            document.querySelector('.person-btn[data-person="1"]').classList.add('active');

            uploadStatus.textContent = '✓ PDF chargé';
            uploadStatus.className = 'status-msg success';

            renderPages();
            document.getElementById('step-upload').classList.add('hidden');
            document.getElementById('step-zones').classList.remove('hidden');

            document.getElementById('btn-send-tablet').disabled = true;
            document.getElementById('btn-send-tablet').textContent = '📲 Envoyer à la tablette';
        } catch (err) {
            uploadStatus.textContent = '✗ ' + err.message;
            uploadStatus.className = 'status-msg error';
        }
    });

    function renderPages() {
        const container = document.getElementById('pdf-pages');
        container.innerHTML = '';
        state.pages.forEach((page, idx) => {
            const wrap = document.createElement('div');
            wrap.className = 'pdf-page-wrap';
            wrap.dataset.page = idx + 1;
            const title = document.createElement('div');
            title.className = 'page-title';
            title.textContent = `Page ${idx + 1}`;
            wrap.appendChild(title);
            const inner = document.createElement('div');
            inner.className = 'pdf-page';
            inner.style.position = 'relative';
            const img = document.createElement('img');
            img.src = page.url; img.draggable = false;
            img.style.display = 'block'; img.style.width = '100%'; img.style.height = 'auto';
            inner.appendChild(img);
            inner.addEventListener('click', (e) => onPageClick(e, idx + 1, inner, img));
            wrap.appendChild(inner);
            container.appendChild(wrap);
        });
    }

    function onPageClick(e, pageNum, container, img) {
        const rect = img.getBoundingClientRect();
        const relX = (e.clientX - rect.left) / rect.width;
        const relY = (e.clientY - rect.top) / rect.height;
        state.zones = state.zones.filter(z => !(z.person === state.activePerson));
        state.zones.push({
            person: state.activePerson, page: pageNum,
            rel_x: relX, rel_y: relY,
            rel_w: ZONE_W / rect.width, rel_h: ZONE_H / rect.height,
            label: state.personLabels[state.activePerson],
        });
        redrawZones();
        checkZonesComplete();
    }

    function redrawZones() {
        document.querySelectorAll('.sig-zone').forEach(el => el.remove());
        state.zones.forEach(zone => {
            const pageWrap = document.querySelector(`.pdf-page-wrap[data-page="${zone.page}"] .pdf-page`);
            if (!pageWrap) return;
            const div = document.createElement('div');
            div.className = 'sig-zone sig-zone-p' + zone.person;
            div.style.position = 'absolute';
            div.style.left = (zone.rel_x * 100) + '%';
            div.style.top = (zone.rel_y * 100) + '%';
            div.style.width = (zone.rel_w * 100) + '%';
            div.style.height = (zone.rel_h * 100) + '%';
            div.textContent = 'Signature : ' + zone.label;
            pageWrap.appendChild(div);
        });
    }

    function checkZonesComplete() {
        const hasP1 = state.zones.some(z => z.person === 1);
        const hasP2 = state.zones.some(z => z.person === 2);
        document.getElementById('btn-send-tablet').disabled = !(hasP1 && hasP2);
    }

    document.querySelectorAll('.person-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            document.querySelectorAll('.person-btn').forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
            state.activePerson = parseInt(btn.dataset.person, 10);
        });
    });

    document.getElementById('btn-reset-zones').addEventListener('click', () => {
        state.zones = [];
        redrawZones();
        checkZonesComplete();
    });

    document.getElementById('btn-send-tablet').addEventListener('click', async () => {
        const btn = document.getElementById('btn-send-tablet');
        btn.disabled = true;
        btn.textContent = 'Envoi…';
        try {
            const r1 = await fetch('/api/set_zones.php', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    csrf_token: window.APP_CSRF,
                    doc_id: state.docId,
                    zones: state.zones,
                })
            });
            const d1 = await r1.json();
            if (!d1.success) throw new Error(d1.error);

            const r2 = await fetch('/api/send_to_tablet.php', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ csrf_token: window.APP_CSRF, doc_id: state.docId })
            });
            const d2 = await r2.json();
            if (!d2.success) throw new Error(d2.error);

            state.trackedDocs[state.docId] = {
                doc_id: state.docId,
                p1_label: state.personLabels[1],
                p2_label: state.personLabels[2],
                status: 'waiting_signatures',
                signed_1: false, signed_2: false,
            };

            state.docId = null; state.pages = []; state.zones = [];
            uploadForm.reset();

            document.getElementById('step-zones').classList.add('hidden');
            document.getElementById('step-upload').classList.remove('hidden');
            document.getElementById('step-tracking').classList.remove('hidden');
            uploadStatus.textContent = '✓ Document envoyé à la tablette — vous pouvez en préparer un nouveau';
            uploadStatus.className = 'status-msg success';

            renderTracking();
            startPolling();
        } catch (err) {
            alert('Erreur : ' + err.message);
            btn.disabled = false;
            btn.textContent = '📲 Envoyer à la tablette';
        }
    });

    function renderTracking() {
        const container = document.getElementById('tracking-list');
        const ids = Object.keys(state.trackedDocs);
        if (ids.length === 0) {
            container.innerHTML = '<p class="help">Aucun document en cours de signature.</p>';
            return;
        }
        container.innerHTML = ids.map(id => {
            const d = state.trackedDocs[id];
            const p1 = d.signed_1, p2 = d.signed_2;
            const completed = d.status === 'completed';
            const statusLabel = completed
                ? '✓ Signé par les 2 — PDF prêt'
                : (p1 || p2 ? 'Signature en cours…' : 'En attente sur la tablette…');
            const statusClass = completed ? 'success' : (p1 || p2 ? 'pending' : 'waiting');
            return `
                <div class="tracked-doc ${statusClass}" data-id="${id}">
                    <div class="tracked-header">
                        <div class="tracked-title">📄 ${escapeHtml(d.original_filename || 'Document')}</div>
                        <div class="tracked-status status-${statusClass}">${statusLabel}</div>
                    </div>
                    <div class="tracked-signers">
                        <div class="sig-item ${p1 ? 'signed' : ''}">
                            <span class="sig-dot"></span>
                            <span class="sig-name">${escapeHtml(d.p1_label)}</span>
                            <span class="sig-state">${p1 ? '✓ Signé' : 'En attente'}</span>
                        </div>
                        <div class="sig-item ${p2 ? 'signed' : ''}">
                            <span class="sig-dot"></span>
                            <span class="sig-name">${escapeHtml(d.p2_label)}</span>
                            <span class="sig-state">${p2 ? '✓ Signé' : 'En attente'}</span>
                        </div>
                    </div>
                    ${completed ? `<button type="button" class="btn btn-success btn-dl" data-dl="${id}">⬇️ Télécharger le PDF signé</button>` : ''}
                </div>`;
        }).join('');

        container.querySelectorAll('.btn-dl').forEach(b => {
            b.addEventListener('click', () => {
                const id = b.dataset.dl;
                window.location.href = '/api/download.php?doc_id=' + encodeURIComponent(id);
                setTimeout(() => { delete state.trackedDocs[id]; renderTracking(); }, 2000);
            });
        });
    }

    function escapeHtml(s) {
        return String(s || '').replace(/[&<>"']/g, c => ({
            '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
        }[c]));
    }

    function startPolling() {
        if (state.pollTimer) return;
        state.pollTimer = setInterval(pollAll, 3000);
    }

    async function pollAll() {
        const ids = Object.keys(state.trackedDocs);
        if (ids.length === 0) return;
        for (const id of ids) {
            if (state.trackedDocs[id].status === 'completed') continue;
            try {
                const r = await fetch('/api/status.php?doc_id=' + encodeURIComponent(id));
                const d = await r.json();
                if (!d.success) continue;
                state.trackedDocs[id].status = d.status;
                state.trackedDocs[id].signed_1 = d.signed_1;
                state.trackedDocs[id].signed_2 = d.signed_2;
                state.trackedDocs[id].original_filename = d.original_filename;
            } catch (e) {}
        }
        renderTracking();
    }
})();
JSEOF

# ============================================================
# JS : tablet.js
# ============================================================
cat > "$INSTALL_PATH/assets/js/tablet.js" <<'JSEOF'
(function() {
    'use strict';
    window.APP_CSRF = document.querySelector('meta[name="csrf-token"]').content;

    const state = {
        currentDocId: null,
        readingPage: 1, readingTotalPages: 1, readingZoom: 1,
        currentDocData: null, sigInstance: null, activeZone: null,
        pollTimer: null, lockUntil: 0, mode: 'list',
    };

    const listScreen = document.getElementById('list-screen');
    const docScreen = document.getElementById('document-screen');
    const listEl = document.getElementById('documents-list');
    const listCount = document.getElementById('list-count');
    const emptyState = document.getElementById('empty-state');
    const pagesContainer = document.getElementById('pages-container');
    const sigPanel = document.getElementById('signature-panel');
    const sigTitle = document.getElementById('sig-zone-label');
    const banner = document.getElementById('current-signer-banner');
    const canvas = document.getElementById('signature-canvas');
    const btnClear = document.getElementById('btn-clear');
    const btnValidate = document.getElementById('btn-validate');
    const btnBack = document.getElementById('btn-back');
    const toast = document.getElementById('toast');
    const readingScreen = document.getElementById('reading-screen');
    const readingTitle = document.getElementById('reading-title');
    const readingImg = document.getElementById('reading-page-img');
    const readingWrapper = document.getElementById('reading-page-wrapper');
    const pageCurrentEl = document.getElementById('page-current');
    const pageTotalEl = document.getElementById('page-total');
    const btnPrevPage = document.getElementById('btn-prev-page');
    const btnNextPage = document.getElementById('btn-next-page');
    const btnStartSigning = document.getElementById('btn-start-signing');
    const btnBackList = document.getElementById('btn-back-list');
    const btnZoomIn = document.getElementById('btn-zoom-in');
    const btnZoomOut = document.getElementById('btn-zoom-out');
    const btnZoomReset = document.getElementById('btn-zoom-reset');

    state.sigInstance = SignatureCanvas.create(canvas);

    btnClear.addEventListener('click', () => state.sigInstance.clear());
    btnBack.addEventListener('click', () => returnToList());

    function showScreen(name) {
        listScreen.classList.toggle('hidden', name !== 'list');
        readingScreen.classList.toggle('hidden', name !== 'reading');
        docScreen.classList.toggle('hidden', name !== 'document');
        state.mode = name;
    }

    function showToast(message, type = 'success') {
        if (!toast) return;
        const icon = toast.querySelector('.toast-icon');
        const text = toast.querySelector('.toast-text');
        if (icon) icon.textContent = type === 'success' ? '✓' : '⚠';
        if (text) text.textContent = message;
        toast.className = 'toast ' + type;
        setTimeout(() => toast && toast.classList.add('hidden'), 2500);
    }

    async function refreshList() {
        if (state.mode !== 'list') return;
        try {
            const r = await fetch('/api/status.php?list=1');
            const d = await r.json();
            if (!d.success) return;
            renderList(d.documents || []);
        } catch (e) {}
    }

    function renderList(docs) {
        listCount.textContent = docs.length;
        if (docs.length === 0) {
            listEl.innerHTML = '';
            emptyState.classList.remove('hidden');
            return;
        }
        emptyState.classList.add('hidden');
        listEl.innerHTML = docs.map(d => {
            const p1Done = d.signed_1, p2Done = d.signed_2;
            const sentDate = d.sent_at ? new Date(d.sent_at * 1000).toLocaleString('fr-FR', {
                day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit'
            }) : '';
            const progressText = p1Done
                ? `Plus que ${d.p2_label} à signer`
                : `${d.p1_label} et ${d.p2_label}`;
            return `
                <div class="doc-card" data-id="${d.doc_id}">
                    <div class="doc-card-header">
                        <div class="doc-card-icon">📄</div>
                        <div class="doc-card-title">
                            <div class="doc-filename">${escapeHtml(d.original_filename)}</div>
                            <div class="doc-date">Envoyé le ${sentDate}</div>
                        </div>
                    </div>
                    <div class="doc-signers">
                        <div class="signer-chip ${p1Done ? 'done' : ''}">
                            ${p1Done ? '✓' : '✍️'} ${escapeHtml(d.p1_label)}
                        </div>
                        <div class="signer-chip ${p2Done ? 'done' : ''}">
                            ${p2Done ? '✓' : '✍️'} ${escapeHtml(d.p2_label)}
                        </div>
                    </div>
                    <div class="doc-action">
                        <span class="doc-progress">${escapeHtml(progressText)}</span>
                        <span class="doc-arrow">→</span>
                    </div>
                </div>`;
        }).join('');
        listEl.querySelectorAll('.doc-card').forEach(card => {
            card.addEventListener('click', () => openDocument(card.dataset.id));
        });
    }

    function escapeHtml(s) {
        return String(s || '').replace(/[&<>"']/g, c => ({
            '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
        }[c]));
    }

    async function openDocument(docId) {
        try {
            const r = await fetch('/api/status.php?doc_id=' + encodeURIComponent(docId));
            const d = await r.json();
            if (!d.success || !d.document) {
                showToast('Document indisponible', 'error');
                refreshList();
                return;
            }
            state.currentDocId = d.document.doc_id;
            state.currentDocData = d.document;
            openReadingScreen(d.document);
        } catch (e) {
            showToast('Erreur de chargement', 'error');
        }
    }

    function openReadingScreen(doc) {
        readingTitle.textContent = doc.original_filename || doc.filename || 'Document';
        state.readingPage = 1;
        state.readingTotalPages = doc.pages.length;
        state.readingZoom = 1;
        pageTotalEl.textContent = state.readingTotalPages;
        renderReadingPage();
        showScreen('reading');
    }

    function renderReadingPage() {
        const doc = state.currentDocData;
        if (!doc) return;
        const page = doc.pages[state.readingPage - 1];
        readingImg.src = page.image_url || page.url || page.preview_url || page;
        pageCurrentEl.textContent = state.readingPage;
        btnPrevPage.disabled = state.readingPage <= 1;
        btnNextPage.disabled = state.readingPage >= state.readingTotalPages;
        applyZoom();
    }

    function applyZoom() {
        readingWrapper.style.transform = `scale(${state.readingZoom})`;
    }

    btnPrevPage.addEventListener('click', () => {
        if (state.readingPage > 1) { state.readingPage--; renderReadingPage(); }
    });
    btnNextPage.addEventListener('click', () => {
        if (state.readingPage < state.readingTotalPages) { state.readingPage++; renderReadingPage(); }
    });
    btnZoomIn.addEventListener('click', () => {
        state.readingZoom = Math.min(3, state.readingZoom + 0.25); applyZoom();
    });
    btnZoomOut.addEventListener('click', () => {
        state.readingZoom = Math.max(0.5, state.readingZoom - 0.25); applyZoom();
    });
    btnZoomReset.addEventListener('click', () => {
        state.readingZoom = 1; applyZoom();
    });

    let lastTap = 0;
    readingImg.addEventListener('click', () => {
        const now = Date.now();
        if (now - lastTap < 300) {
            state.readingZoom = state.readingZoom === 1 ? 2 : 1;
            applyZoom();
        }
        lastTap = now;
    });

    btnBackList.addEventListener('click', () => {
        state.currentDocId = null;
        state.currentDocData = null;
        showScreen('list');
        refreshList();
    });

    btnStartSigning.addEventListener('click', () => {
        renderDocument(state.currentDocData);
        updateSignerPanel(state.currentDocData);
        showScreen('document');
    });

    function renderDocument(doc) {
        pagesContainer.innerHTML = '';
        document.getElementById('doc-title').textContent =
            `${doc.p1_label} & ${doc.p2_label}`;

        doc.pages.forEach((page, idx) => {
            const wrap = document.createElement('div');
            wrap.className = 'tablet-page-wrap';
            wrap.dataset.page = idx + 1;

            const inner = document.createElement('div');
            inner.className = 'tablet-page';
            inner.style.position = 'relative';

            const img = document.createElement('img');
            img.src = page.url;
            img.draggable = false;
            inner.appendChild(img);

            doc.zones.filter(z => z.page === (idx + 1)).forEach(zone => {
                const zd = document.createElement('div');
                zd.className = 'tablet-sig-zone sig-zone-p' + zone.person;
                zd.style.left = (zone.rel_x * 100) + '%';
                zd.style.top = (zone.rel_y * 100) + '%';
                zd.style.width = (zone.rel_w * 100) + '%';
                zd.style.height = (zone.rel_h * 100) + '%';
                zd.dataset.person = zone.person;
                zd.textContent = 'Signature : ' + zone.label;
                inner.appendChild(zd);
            });

            wrap.appendChild(inner);
            pagesContainer.appendChild(wrap);
        });
    }

    function updateSignerPanel(doc) {
        const p1Done = !!doc.signed_1;
        const p2Done = !!doc.signed_2;
        let nextPerson = null;
        if (!p1Done) nextPerson = 1;
        else if (!p2Done) nextPerson = 2;

        if (nextPerson === null) {
            sigPanel.classList.add('hidden');
            return;
        }
        const label = nextPerson === 1 ? doc.p1_label : doc.p2_label;
        banner.textContent = `✍️ À ${label} de signer`;
        banner.className = 'signer-banner person-' + nextPerson;
        sigTitle.textContent = `Signature de : ${label}`;
        state.activeZone = nextPerson;
        sigPanel.classList.remove('hidden');
        state.sigInstance.clear();
        setTimeout(() => state.sigInstance.resize(), 100);
    }

    btnValidate.addEventListener('click', async () => {
        if (state.sigInstance.isEmpty()) {
            showToast('Veuillez signer avant de valider.', 'error');
            return;
        }
        if (!state.activeZone || !state.currentDocId) return;

        btnValidate.disabled = true;
        btnValidate.textContent = 'Envoi…';
        state.lockUntil = Date.now() + 5000;

        const b64 = state.sigInstance.toBase64();
        try {
            const r = await fetch('/api/sign.php', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    csrf_token: window.APP_CSRF,
                    doc_id: state.currentDocId,
                    person: state.activeZone,
                    signature_png: b64,
                })
            });
            const data = await r.json();
            if (!data.success) throw new Error(data.error || 'Erreur');

            showToast('Signature enregistrée !', 'success');
            state.sigInstance.clear();
            state.currentDocId = null;
            state.currentDocData = null;
            setTimeout(() => returnToList(), 800);
        } catch (err) {
            showToast('Erreur : ' + err.message, 'error');
            btnValidate.disabled = false;
            btnValidate.textContent = '✓ Valider ma signature';
        }
    });

    function returnToList() {
        state.currentDocId = null;
        state.currentDocData = null;
        showScreen('list');
        refreshList();
    }

    // Polling liste
    setInterval(() => {
        if (Date.now() < state.lockUntil) return;
        refreshList();
    }, 4000);

    refreshList();
})();
JSEOF

ok "JS générés (3 fichiers)"

# ============================================================
# index.php (redirection)
# ============================================================
cat > "$INSTALL_PATH/index.php" <<'PHPEOF'
<?php
require_once __DIR__ . '/config/config.php';
if (!isset($_SESSION['role'])) { header('Location: /login.php'); exit; }
header('Location: ' . ($_SESSION['role'] === 'pc' ? '/pc/index.php' : '/tablet/index.php'));
exit;
PHPEOF

# ============================================================
# login.php
# ============================================================
cat > "$INSTALL_PATH/login.php" <<'PHPEOF'
<?php
require_once __DIR__ . '/config/config.php';
$error = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $user = trim($_POST['username'] ?? '');
    $pass = $_POST['password'] ?? '';
    if (isset(USERS[$user]) && password_verify($pass, USERS[$user]['pass'])) {
        session_regenerate_id(true);
        $_SESSION['user'] = $user;
        $_SESSION['role'] = USERS[$user]['role'];
        header('Location: /');
        exit;
    }
    $error = 'Identifiants invalides';
    sleep(1);
}
$csrf = csrf_token();
?><!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="csrf-token" content="<?= htmlspecialchars($csrf) ?>">
<title>Connexion — Signature</title>
<link rel="stylesheet" href="/assets/css/style.css">
</head>
<body class="login-body">
<div class="login-box">
    <h1>✍️ Signature Électronique</h1>
    <p class="subtitle">Veuillez vous connecter</p>
    <?php if ($error): ?><div class="alert alert-error"><?= htmlspecialchars($error) ?></div><?php endif; ?>
    <form method="POST" autocomplete="off">
        <label>Identifiant<input type="text" name="username" required autofocus></label>
        <label>Mot de passe<input type="password" name="password" required></label>
        <button type="submit" class="btn btn-primary">Se connecter</button>
    </form>
</div>
</body>
</html>
PHPEOF

# ============================================================
# logout.php
# ============================================================
cat > "$INSTALL_PATH/logout.php" <<'PHPEOF'
<?php
require_once __DIR__ . '/config/config.php';
$_SESSION = [];
session_destroy();
header('Location: /login.php');
exit;
PHPEOF

# ============================================================
# pc/index.php
# ============================================================
cat > "$INSTALL_PATH/pc/index.php" <<'PHPEOF'
<?php
require_once __DIR__ . '/../config/config.php';
require_role('pc');
$csrf = csrf_token();
?><!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="csrf-token" content="<?= htmlspecialchars($csrf) ?>">
<title>PC — Signature</title>
<link rel="stylesheet" href="/assets/css/style.css">
<link rel="stylesheet" href="/assets/css/pc.css">
</head>
<body>
<div class="top-bar">
    <h1>✍️ Signature Électronique — Gestionnaire</h1>
    <div class="user-info">
        <span><?= htmlspecialchars($_SESSION['user']) ?></span>
        <a href="/logout.php" class="btn btn-ghost">Déconnexion</a>
    </div>
</div>

<div class="container">
    <section id="step-upload" class="card">
        <h2>1. Charger un PDF et renseigner les signataires</h2>
        <form id="upload-form" enctype="multipart/form-data">
            <input type="hidden" name="csrf_token" value="<?= htmlspecialchars($csrf) ?>">
            <div class="form-row">
                <label>Document PDF (max 10 Mo)
                    <input type="file" name="pdf" accept="application/pdf" required>
                </label>
            </div>
            <div class="form-row-double">
                <fieldset>
                    <legend>Signataire 1</legend>
                    <label>Prénom<input type="text" name="p1_firstname" required maxlength="50"></label>
                    <label>Nom<input type="text" name="p1_lastname" required maxlength="50"></label>
                </fieldset>
                <fieldset>
                    <legend>Signataire 2</legend>
                    <label>Prénom<input type="text" name="p2_firstname" required maxlength="50"></label>
                    <label>Nom<input type="text" name="p2_lastname" required maxlength="50"></label>
                </fieldset>
            </div>
            <button type="submit" class="btn btn-primary">Charger le PDF</button>
            <div id="upload-status" class="status-msg"></div>
        </form>
    </section>

    <section id="step-zones" class="card hidden">
        <h2>2. Placer les zones de signature</h2>
        <p class="help">Cliquez sur la page à l'endroit où doit se trouver la signature de chaque personne.</p>
        <div class="person-selector">
            <button type="button" class="person-btn active" data-person="1">👤 <span id="label-p1">Signataire 1</span></button>
            <button type="button" class="person-btn" data-person="2">👤 <span id="label-p2">Signataire 2</span></button>
        </div>
        <div id="pdf-pages" class="pdf-pages"></div>
        <div class="actions-row">
            <button type="button" id="btn-reset-zones" class="btn btn-ghost">Réinitialiser</button>
            <button type="button" id="btn-send-tablet" class="btn btn-primary" disabled>📲 Envoyer à la tablette</button>
        </div>
    </section>

    <section id="step-tracking" class="card hidden">
        <h2>3. Suivi des signatures</h2>
        <div id="tracking-list" class="tracking-list"></div>
    </section>
</div>

<script src="/assets/js/pc.js"></script>
</body>
</html>
PHPEOF

# ============================================================
# tablet/index.php
# ============================================================
cat > "$INSTALL_PATH/tablet/index.php" <<'PHPEOF'
<?php
require_once __DIR__ . '/../config/config.php';
require_role('tablet');
$csrf = csrf_token();
?><!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<meta name="csrf-token" content="<?= htmlspecialchars($csrf) ?>">
<title>Tablette — Signature</title>
<link rel="stylesheet" href="/assets/css/style.css">
<link rel="stylesheet" href="/assets/css/tablet.css">
</head>
<body class="tablet-body">

<div id="list-screen" class="list-screen">
    <div class="list-header">
        <h1>📋 Documents à signer</h1>
        <div class="list-count"><span id="list-count">0</span> document(s) en attente</div>
    </div>
    <div id="empty-state" class="empty-state hidden">
        <div class="big-icon">📭</div>
        <h2>Aucun document en attente</h2>
        <p>Les nouveaux documents apparaîtront ici.</p>
    </div>
    <div id="documents-list" class="documents-list"></div>
</div>

<div id="reading-screen" class="reading-screen hidden">
    <div class="reading-header">
        <button type="button" id="btn-back-list" class="btn btn-ghost btn-back">← Liste</button>
        <h2 id="reading-title">Document</h2>
        <div class="page-indicator"><span id="page-current">1</span> / <span id="page-total">1</span></div>
    </div>
    <div class="reading-viewport">
        <div id="reading-page-wrapper" class="reading-page-wrapper">
            <img id="reading-page-img" alt="">
        </div>
    </div>
    <div class="reading-footer">
        <button type="button" id="btn-prev-page" class="btn btn-nav">◀ Précédent</button>
        <div class="zoom-controls">
            <button type="button" id="btn-zoom-out" class="btn">−</button>
            <button type="button" id="btn-zoom-reset" class="btn">100%</button>
            <button type="button" id="btn-zoom-in" class="btn">+</button>
        </div>
        <button type="button" id="btn-start-signing" class="btn btn-sign">✍️ Signer</button>
        <button type="button" id="btn-next-page" class="btn btn-nav">Suivant ▶</button>
    </div>
</div>

<div id="document-screen" class="hidden">
    <div class="tablet-header">
        <button type="button" id="btn-back" class="btn btn-ghost btn-back">← Retour</button>
        <h2 id="doc-title">Document</h2>
        <div id="current-signer-banner" class="signer-banner"></div>
    </div>
    <div id="doc-content">
        <div id="pages-container"></div>
        <div id="signature-panel" class="signature-panel hidden">
            <div class="signature-header">
                <h3 id="sig-zone-label">Signature</h3>
            </div>
            <canvas id="signature-canvas"></canvas>
            <div class="signature-actions">
                <button type="button" id="btn-clear" class="btn-big btn-ghost">🗑 Effacer</button>
                <button type="button" id="btn-validate" class="btn-big btn-primary">✓ Valider ma signature</button>
            </div>
        </div>
    </div>
</div>

<div id="toast" class="toast hidden">
    <span class="toast-icon">✓</span>
    <span class="toast-text"></span>
</div>

<script src="/assets/js/signature_canvas.js"></script>
<script src="/assets/js/tablet.js"></script>
</body>
</html>
PHPEOF

ok "Pages HTML générées (login, logout, index, pc, tablet)"

# ============================================================
# cleanup.php (cron)
# ============================================================
cat > "$INSTALL_PATH/cleanup.php" <<'PHPEOF'
<?php
// Nettoyage périodique — à lancer en cron (ex: toutes les nuits)
require_once __DIR__ . '/config/config.php';
cleanup_storage();
echo "[cleanup] " . date('Y-m-d H:i:s') . " OK\n";
PHPEOF

# ============================================================
# .htaccess (Apache seulement, ignoré par Nginx)
# ============================================================
cat > "$INSTALL_PATH/storage/.htaccess" <<'EOF'
Require all denied
<FilesMatch "\.(php|phtml|phar)$">
    Require all denied
</FilesMatch>
EOF
cp "$INSTALL_PATH/storage/.htaccess" "$INSTALL_PATH/config/.htaccess"
cp "$INSTALL_PATH/storage/.htaccess" "$INSTALL_PATH/libs/.htaccess"

ok "cleanup.php + .htaccess déployés"

# ============================================================
# LIBS : Téléchargement TCPDF + FPDI
# ============================================================
step "Installation des librairies PHP (TCPDF + FPDI)"

LIBS_PATH="$INSTALL_PATH/libs"
TMP_DL="/tmp/signapp_libs_$$"
mkdir -p "$TMP_DL"
cd "$TMP_DL"

# TCPDF
if [ ! -d "$LIBS_PATH/tcpdf" ]; then
    info "Téléchargement TCPDF…"
    TCPDF_VER="6.7.5"
    wget -q "https://github.com/tecnickcom/TCPDF/archive/refs/tags/$TCPDF_VER.tar.gz" -O tcpdf.tgz || {
        err "Échec téléchargement TCPDF"; exit 1;
    }
    tar xzf tcpdf.tgz
    mv "TCPDF-$TCPDF_VER" "$LIBS_PATH/tcpdf"
    ok "TCPDF $TCPDF_VER installé"
else
    info "TCPDF déjà présent, skip"
fi

# FPDI
if [ ! -d "$LIBS_PATH/FPDI" ]; then
    info "Téléchargement FPDI…"
    FPDI_VER="2.6.1"
    wget -q "https://github.com/Setasign/FPDI/archive/refs/tags/v$FPDI_VER.tar.gz" -O fpdi.tgz || {
        err "Échec téléchargement FPDI"; exit 1;
    }
    tar xzf fpdi.tgz
    mv "FPDI-$FPDI_VER" "$LIBS_PATH/FPDI"
    ok "FPDI $FPDI_VER installé"
else
    info "FPDI déjà présent, skip"
fi

cd /tmp
rm -rf "$TMP_DL"

# Test chargement libs
info "Test de chargement des libs…"
php -r "
require '$LIBS_PATH/tcpdf/tcpdf.php';
require '$LIBS_PATH/FPDI/src/autoload.php';
echo 'TCPDF + FPDI OK' . PHP_EOL;
" || { err "Les libs ne se chargent pas correctement"; exit 1; }

# ============================================================
# PERMISSIONS
# ============================================================
step "Application des permissions"

WEB_USER="www-data"
if ! id "$WEB_USER" >/dev/null 2>&1; then
    warn "Utilisateur $WEB_USER introuvable, détection automatique…"
    WEB_USER=$(ps aux | grep -E 'apache|nginx|php-fpm' | grep -v root | grep -v grep | awk '{print $1}' | sort -u | head -1)
    [ -z "$WEB_USER" ] && WEB_USER="www-data"
    info "Utilisateur web détecté : $WEB_USER"
fi

chown -R "$WEB_USER:$WEB_USER" "$INSTALL_PATH"
find "$INSTALL_PATH" -type d -exec chmod 750 {} \;
find "$INSTALL_PATH" -type f -exec chmod 640 {} \;
chmod 750 "$INSTALL_PATH/cleanup.php"

# storage/ doit être écrivable
chmod -R 770 "$INSTALL_PATH/storage"
chmod 600 "$INSTALL_PATH/config/config.php"

ok "Permissions appliquées ($WEB_USER)"

# ============================================================
# VHOST APACHE
# ============================================================
step "Configuration du VirtualHost Apache"

VHOST_FILE="/etc/apache2/sites-available/$VHOST_NAME.conf"
SSL_DIR="/etc/ssl/signapp"
mkdir -p "$SSL_DIR"

# Génération certif self-signed si absent
if [ ! -f "$SSL_DIR/server.crt" ]; then
    info "Génération certificat auto-signé…"
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$SSL_DIR/server.key" \
        -out "$SSL_DIR/server.crt" \
        -subj "/C=FR/ST=Local/L=Local/O=SignApp/CN=$VHOST_NAME" 2>/dev/null
    chmod 600 "$SSL_DIR/server.key"
    ok "Certificat généré dans $SSL_DIR"
fi

cat > "$VHOST_FILE" <<VHEOF
# Redirection HTTP → HTTPS
<VirtualHost *:80>
    ServerName $VHOST_NAME
    Redirect permanent / https://$VHOST_NAME/
</VirtualHost>

<VirtualHost *:443>
    ServerName $VHOST_NAME
    DocumentRoot $INSTALL_PATH

    SSLEngine on
    SSLCertificateFile $SSL_DIR/server.crt
    SSLCertificateKeyFile $SSL_DIR/server.key

    <Directory $INSTALL_PATH>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <DirectoryMatch "^$INSTALL_PATH/(storage|config|libs)">
        Require all denied
    </DirectoryMatch>

    <FilesMatch "\.(htaccess|json|log)$">
        Require all denied
    </FilesMatch>

    # Limites upload
    LimitRequestBody 15728640

    # Sécurité headers
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set Strict-Transport-Security "max-age=31536000"

    ErrorLog \${APACHE_LOG_DIR}/signapp_error.log
    CustomLog \${APACHE_LOG_DIR}/signapp_access.log combined
</VirtualHost>
VHEOF

# Activer modules
a2enmod ssl rewrite headers >/dev/null 2>&1 || true
a2ensite "$VHOST_NAME" >/dev/null 2>&1 || true

# Upload PHP limits
PHP_INI=$(php -i | grep "Loaded Configuration File" | awk '{print $NF}')
if [ -f "$PHP_INI" ]; then
    sed -i 's/^upload_max_filesize.*/upload_max_filesize = 15M/' "$PHP_INI"
    sed -i 's/^post_max_size.*/post_max_size = 16M/' "$PHP_INI"
    sed -i 's/^memory_limit.*/memory_limit = 1024M/' "$PHP_INI"
    sed -i 's/^max_execution_time.*/max_execution_time = 600/' "$PHP_INI"
    info "php.ini ajusté : $PHP_INI"
fi

# PHP-FPM ini (si utilisé)
for fpm_ini in /etc/php/*/fpm/php.ini; do
    [ -f "$fpm_ini" ] || continue
    sed -i 's/^upload_max_filesize.*/upload_max_filesize = 15M/' "$fpm_ini"
    sed -i 's/^post_max_size.*/post_max_size = 16M/' "$fpm_ini"
    sed -i 's/^memory_limit.*/memory_limit = 1024M/' "$fpm_ini"
    sed -i 's/^max_execution_time.*/max_execution_time = 600/' "$fpm_ini"
done

# Reload services
info "Reload Apache…"
apachectl configtest && systemctl reload apache2 || {
    err "Erreur de config Apache. Vérifie avec : apachectl configtest"
    exit 1
}

# Reload PHP-FPM si présent
for svc in $(systemctl list-units --type=service --state=running | grep -oE 'php[0-9.]+-fpm' | sort -u); do
    systemctl reload "$svc" 2>/dev/null && info "Reloaded $svc"
done

ok "Apache configuré et rechargé"

# ============================================================
# CRON
# ============================================================
step "Installation de la tâche cron (cleanup nocturne)"

CRON_LINE="17 3 * * * $WEB_USER php $INSTALL_PATH/cleanup.php >> /var/log/signapp_cleanup.log 2>&1"
CRON_FILE="/etc/cron.d/signapp"
echo "$CRON_LINE" > "$CRON_FILE"
chmod 644 "$CRON_FILE"
touch /var/log/signapp_cleanup.log
chown "$WEB_USER:$WEB_USER" /var/log/signapp_cleanup.log

ok "Cron installé : $CRON_FILE"

# ============================================================
# TESTS FINAUX
# ============================================================
step "Tests de vérification"

T_OK=0; T_KO=0
check() {
    if eval "$2" >/dev/null 2>&1; then
        echo "  ✅ $1"; T_OK=$((T_OK+1))
    else
        echo "  ❌ $1"; T_KO=$((T_KO+1))
    fi
}

check "Dossier installation" "[ -d '$INSTALL_PATH' ]"
check "config.php présent"    "[ -f '$INSTALL_PATH/config/config.php' ]"
check "TCPDF chargeable"      "php -r \"require '$LIBS_PATH/tcpdf/tcpdf.php';\""
check "FPDI chargeable"       "php -r \"require '$LIBS_PATH/FPDI/src/autoload.php';\""
check "storage/ écrivable"    "sudo -u $WEB_USER test -w '$INSTALL_PATH/storage'"
check "Apache actif"          "systemctl is-active apache2"
check "Port 443 en écoute"    "ss -tln | grep -q ':443'"
check "Cron installé"         "[ -f '$CRON_FILE' ]"
check "Syntaxe config.php"    "php -l '$INSTALL_PATH/config/config.php'"
check "Syntaxe upload.php"    "php -l '$INSTALL_PATH/api/upload.php'"
check "Syntaxe sign.php"      "php -l '$INSTALL_PATH/api/sign.php'"
check "Syntaxe tablet/index"  "php -l '$INSTALL_PATH/tablet/index.php'"
check "Syntaxe pc/index"      "php -l '$INSTALL_PATH/pc/index.php'"

echo
if [ "$T_KO" -eq 0 ]; then
    ok "Tous les tests passent ($T_OK/$T_OK)"
else
    warn "$T_KO test(s) échoué(s) sur $((T_OK+T_KO))"
fi

# ============================================================
# RÉCAPITULATIF FINAL
# ============================================================
echo
echo "════════════════════════════════════════════════════════════"
echo "   🎉  DÉPLOIEMENT TERMINÉ"
echo "════════════════════════════════════════════════════════════"
echo
echo "  📁 Installation    : $INSTALL_PATH"
echo "  🌐 URL             : https://$VHOST_NAME/"
echo "  👤 Web user        : $WEB_USER"
echo "  🔐 Certificat SSL  : $SSL_DIR/ (self-signed, 10 ans)"
echo "  📋 VHost           : $VHOST_FILE"
echo "  🗑️  Cron cleanup    : $CRON_FILE (tous les jours à 03h17)"
echo "  📜 Logs Apache     : /var/log/apache2/signapp_*.log"
echo "  📜 Logs cleanup    : /var/log/signapp_cleanup.log"
echo
echo "  🔑 COMPTES UTILISATEURS :"
echo "       PC / Gestionnaire  : $PC_USER  / (mot de passe défini à l'install)"
echo "       Tablette           : $TABLET_USER / (mot de passe défini à l'install)"
echo
echo "  📝 PROCHAINES ÉTAPES :"
echo "     1. Ajouter '$VHOST_NAME' dans /etc/hosts du poste client si besoin"
echo "        ou configurer le DNS local vers l'IP de ce serveur."
echo "     2. Accepter le certificat auto-signé au premier accès HTTPS."
echo "     3. Se connecter sur https://$VHOST_NAME/login.php"
echo "     4. Pour regénérer les mots de passe :"
echo "        php -r \"echo password_hash('NEWPASS', PASSWORD_DEFAULT) . PHP_EOL;\""
echo "        puis éditer $INSTALL_PATH/config/config.php"
echo
echo "  🛠️  DÉBOGAGE :"
echo "     • Tail erreurs    : tail -f /var/log/apache2/signapp_error.log"
echo "     • Tail cleanup    : tail -f /var/log/signapp_cleanup.log"
echo "     • Test cleanup    : sudo -u $WEB_USER php $INSTALL_PATH/cleanup.php"
echo "     • Permissions     : ls -la $INSTALL_PATH/storage/"
echo
echo "════════════════════════════════════════════════════════════"
echo

exit 0
