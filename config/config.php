<?php
// /config/config.php
// Configuration centrale de l'application
// ⚠️  AVANT de pousser sur GitHub :
//     1. Ne jamais committer ce fichier avec de vrais mots de passe/clés
//     2. Ajouter config/config.php dans .gitignore
//     3. Utiliser config.example.php comme modèle public (ce fichier)

declare(strict_types=1);

// === Clé secrète ===
// ⚠️  Générer avec : php -r "echo bin2hex(random_bytes(32));"
define('SECRET_KEY', 'CHANGE_ME_64_CHARS_RANDOM_STRING');

// === Chemins absolus ===
// ⚠️  Adapter à votre environnement (ex: /var/www/signature)
define('ROOT_PATH', dirname(__DIR__));
define('STORAGE_PATH', ROOT_PATH . '/storage');
define('PDF_PATH',        STORAGE_PATH . '/pdf');
define('PREVIEW_PATH',    STORAGE_PATH . '/previews');
define('SIGNATURES_PATH', STORAGE_PATH . '/signatures');
define('SESSIONS_PATH',   STORAGE_PATH . '/sessions');
define('FINAL_PATH',      STORAGE_PATH . '/final');
define('LIBS_PATH',       ROOT_PATH    . '/libs');

// === Paramètres upload ===
define('MAX_PDF_SIZE',   10 * 1024 * 1024); // 10 Mo max
define('ALLOWED_MIME',   ['application/pdf']);

// === Durées de session ===
define('SESSION_LIFETIME',        8 * 3600);        // 8 heures  (PC)
define('TABLET_SESSION_LIFETIME', 30 * 24 * 3600);  // 30 jours  (tablette)

// === Identifiants ===
// ⚠️  Générer les hashs avec : php -r "echo password_hash('MonMotDePasse', PASSWORD_BCRYPT);"
// Les valeurs ci-dessous sont des EXEMPLES — ne pas utiliser en production
define('USERS', [
    'gestionnaire' => [
        'password_hash' => '$2y$10$REMPLACER_PAR_VOTRE_HASH_PC',   // ex: pc2024!
        'role'          => 'pc',
        'display_name'  => 'Gestionnaire PC',
    ],
    'tablette' => [
        'password_hash' => '$2y$10$REMPLACER_PAR_VOTRE_HASH_TABLET', // ex: tablet2024!
        'role'          => 'tablet',
        'display_name'  => 'Tablette Signature',
    ],
]);

// === Initialisation session PHP ===
if (session_status() === PHP_SESSION_NONE) {
    // ⚠️  Adapter le save_path à votre installation
    ini_set('session.save_path',      ROOT_PATH . '/storage/php_sessions');
    ini_set('session.use_strict_mode',  '1');
    ini_set('session.use_only_cookies', '1');
    ini_set('session.gc_maxlifetime', (string) TABLET_SESSION_LIFETIME);
    ini_set('session.cookie_lifetime', (string) TABLET_SESSION_LIFETIME);

    session_set_cookie_params([
        'lifetime' => TABLET_SESSION_LIFETIME,
        'path'     => '/',
        'domain'   => '',
        'secure'   => (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off'),
        'httponly' => true,
        'samesite' => 'Strict',
    ]);

    session_name('SIGNAPP_SESSID');
    session_start();
}

// === Headers sécurité ===
header('X-Frame-Options: DENY');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: no-referrer');
header("Content-Security-Policy: default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self';");

// === Création automatique des dossiers si absents ===
foreach ([STORAGE_PATH, PDF_PATH, PREVIEW_PATH, SIGNATURES_PATH, SESSIONS_PATH, FINAL_PATH] as $dir) {
    if (!is_dir($dir)) {
        @mkdir($dir, 0755, true);
    }
}

// =============================================================================
// FONCTIONS UTILITAIRES
// =============================================================================

/**
 * Génère (ou retourne) le token CSRF de la session courante.
 */
function generate_csrf_token(): string {
    if (empty($_SESSION['csrf_token'])) {
        $_SESSION['csrf_token'] = bin2hex(random_bytes(32));
    }
    return $_SESSION['csrf_token'];
}

/**
 * Vérifie un token CSRF (comparaison timing-safe).
 */
function verify_csrf_token(?string $token): bool {
    return !empty($token)
        && !empty($_SESSION['csrf_token'])
        && hash_equals($_SESSION['csrf_token'], $token);
}

/**
 * Contrôle d'accès par rôle — redirige vers /login.php si non autorisé.
 */
function require_role(string $role): void {
    if (empty($_SESSION['user']) || ($_SESSION['user']['role'] ?? '') !== $role) {
        header('Location: /login.php');
        exit;
    }
    // Vérification expiration
    if (!empty($_SESSION['user']['login_time'])) {
        $lifetime = ($role === 'tablet') ? TABLET_SESSION_LIFETIME : SESSION_LIFETIME;
        if (time() - $_SESSION['user']['login_time'] > $lifetime) {
            session_unset();
            session_destroy();
            header('Location: /login.php?expired=1');
            exit;
        }
    }
}

/**
 * Envoie une réponse JSON et termine le script.
 */
function json_response(array $data, int $code = 200): void {
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($data);
    exit;
}

/**
 * Charge le JSON d'un document depuis storage/sessions/.
 * Retourne null si introuvable ou invalide.
 */
function load_document(string $doc_id): ?array {
    $doc_id = preg_replace('/[^a-f0-9]/', '', $doc_id);
    if (strlen($doc_id) < 16) return null;

    $file = SESSIONS_PATH . '/' . $doc_id . '.json';
    if (!is_file($file)) return null;

    $fp = fopen($file, 'r');
    if (!$fp) return null;

    flock($fp, LOCK_SH);
    $content = stream_get_contents($fp);
    flock($fp, LOCK_UN);
    fclose($fp);

    $data = json_decode($content, true);
    return is_array($data) ? $data : null;
}

/**
 * Sauvegarde le JSON d'un document (écriture atomique avec verrou exclusif).
 */
function save_document(string $doc_id, array $data): bool {
    $doc_id = preg_replace('/[^a-f0-9]/', '', $doc_id);
    if (strlen($doc_id) < 16) return false;

    $file = SESSIONS_PATH . '/' . $doc_id . '.json';
    $fp   = fopen($file, 'c+');
    if (!$fp) return false;

    flock($fp, LOCK_EX);
    ftruncate($fp, 0);
    rewind($fp);
    fwrite($fp, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
    fflush($fp);
    flock($fp, LOCK_UN);
    fclose($fp);

    return true;
}

/**
 * Retourne le document actif pour la tablette (legacy — préférer get_pending_documents_for_tablet).
 */
function get_active_document_for_tablet(): ?array {
    $files = glob(SESSIONS_PATH . '/*.json');
    if (!$files) return null;

    $candidates = [];
    foreach ($files as $f) {
        $d = json_decode((string) file_get_contents($f), true);
        if (!is_array($d)) continue;
        if (in_array($d['status'] ?? '', ['waiting_signatures', 'signed_by_1'], true)) {
            $candidates[] = $d;
        }
    }
    if (!$candidates) return null;

    usort($candidates, fn($a, $b) => ($b['sent_at'] ?? 0) <=> ($a['sent_at'] ?? 0));
    return $candidates[0];
}

/**
 * Nettoie le nom d'un signataire (supprime les caractères dangereux).
 */
function sanitize_name(string $s): string {
    $s = trim($s);
    $s = preg_replace('/[^\p{L}\p{N}\s\-\'\.]/u', '', $s);
    return mb_substr($s, 0, 50);
}

// =============================================================================
// NETTOYAGE DU STOCKAGE
// =============================================================================

/**
 * Supprime les fichiers temporaires d'un document :
 * PDF source, dossier de previews, signatures PNG.
 * Conserve le JSON de session et le PDF final.
 */
function cleanup_document_cache(string $doc_id): void {
    $doc_id = preg_replace('/[^a-f0-9]/', '', $doc_id);
    if (strlen($doc_id) !== 32) return;

    // PDF source
    $pdf = PDF_PATH . '/' . $doc_id . '.pdf';
    if (is_file($pdf)) @unlink($pdf);

    // Dossier de previews
    $previewDir = PREVIEW_PATH . '/' . $doc_id;
    if (is_dir($previewDir)) {
        foreach (glob($previewDir . '/*') as $f) @unlink($f);
        @rmdir($previewDir);
    }

    // Signatures PNG
    foreach (['p1', 'p2'] as $p) {
        $sig = SIGNATURES_PATH . '/' . $doc_id . '_' . $p . '.png';
        if (is_file($sig)) @unlink($sig);
    }
}

/**
 * Nettoyage global du stockage :
 *  - Brouillons abandonnés > 24h          → suppression complète
 *  - Documents complétés > 30 jours       → suppression complète
 *  - Documents complétés + téléchargés    → suppression du cache uniquement
 *  - Fichiers orphelins (sans JSON)       → suppression
 *
 * @return array Statistiques du nettoyage
 */
function cleanup_storage(): array {
    $stats = [
        'cache_cleaned'   => 0,
        'expired_deleted' => 0,
        'drafts_deleted'  => 0,
        'orphans_deleted' => 0,
    ];

    $now       = time();
    $TTL_FINAL = 30 * 24 * 3600; // 30 jours
    $TTL_DRAFT = 24 * 3600;      // 24 heures

    $files    = glob(SESSIONS_PATH . '/*.json');
    $validIds = [];

    foreach ($files as $f) {
        $doc = json_decode((string) file_get_contents($f), true);
        if (!is_array($doc) || empty($doc['doc_id'])) {
            @unlink($f);
            continue;
        }

        $validIds[$doc['doc_id']] = true;

        // 1. Brouillons abandonnés
        if ($doc['status'] === 'draft' && ($now - ($doc['created_at'] ?? 0)) > $TTL_DRAFT) {
            cleanup_document_cache($doc['doc_id']);
            if (!empty($doc['final_pdf'])) @unlink(FINAL_PATH . '/' . $doc['final_pdf']);
            @unlink($f);
            $stats['drafts_deleted']++;
            continue;
        }

        // 2. Documents expirés (30 jours)
        if ($doc['status'] === 'completed' && ($now - ($doc['completed_at'] ?? 0)) > $TTL_FINAL) {
            cleanup_document_cache($doc['doc_id']);
            if (!empty($doc['final_pdf'])) @unlink(FINAL_PATH . '/' . $doc['final_pdf']);
            @unlink($f);
            $stats['expired_deleted']++;
            continue;
        }

        // 3. Complété + téléchargé → nettoyage cache uniquement
        if ($doc['status'] === 'completed'
            && !empty($doc['downloaded_at'])
            && empty($doc['cache_cleaned'])
        ) {
            cleanup_document_cache($doc['doc_id']);
            $doc['cache_cleaned'] = true;
            save_document($doc['doc_id'], $doc);
            $stats['cache_cleaned']++;
        }
    }

    // 4. Orphelins — PDF source
    foreach (glob(PDF_PATH . '/*.pdf') as $f) {
        $id = pathinfo($f, PATHINFO_FILENAME);
        if (!isset($validIds[$id])) { @unlink($f); $stats['orphans_deleted']++; }
    }

    // 4. Orphelins — dossiers de previews
    foreach (glob(PREVIEW_PATH . '/*', GLOB_ONLYDIR) as $d) {
        $id = basename($d);
        if (!isset($validIds[$id])) {
            foreach (glob($d . '/*') as $f) @unlink($f);
            @rmdir($d);
            $stats['orphans_deleted']++;
        }
    }

    // 4. Orphelins — signatures PNG
    foreach (glob(SIGNATURES_PATH . '/*.png') as $f) {
        $id = preg_replace('/_p[12]\.png$/', '', basename($f));
        if (!isset($validIds[$id])) { @unlink($f); $stats['orphans_deleted']++; }
    }

    // 4. Orphelins — PDF finaux
    foreach (glob(FINAL_PATH . '/*_signed.pdf') as $f) {
        $id = preg_replace('/_signed\.pdf$/', '', basename($f));
        if (!isset($validIds[$id])) { @unlink($f); $stats['orphans_deleted']++; }
    }

    return $stats;
}

/**
 * Retourne la liste des documents en attente de signature (pour la tablette).
 */
function get_pending_documents_for_tablet(): array {
    $files = glob(SESSIONS_PATH . '/*.json');
    if (!$files) return [];

    $list = [];
    foreach ($files as $f) {
        $d = json_decode((string) file_get_contents($f), true);
        if (!is_array($d)) continue;
        if (in_array($d['status'] ?? '', ['waiting_signatures', 'signed_by_1'], true)) {
            $list[] = [
                'doc_id'            => $d['doc_id'],
                'status'            => $d['status'],
                'p1_label'          => $d['p1_label'],
                'p2_label'          => $d['p2_label'],
                'original_filename' => $d['original_filename'] ?? '',
                'sent_at'           => $d['sent_at'] ?? 0,
                'signed_1'          => $d['signed_1'],
                'signed_2'          => $d['signed_2'],
            ];
        }
    }

    usort($list, fn($a, $b) => ($b['sent_at'] ?? 0) <=> ($a['sent_at'] ?? 0));
    return $list;
}

/**
 * Retourne un document complet (formaté pour la tablette) par son ID.
 */
function get_document_for_tablet(string $doc_id): ?array {
    $doc = load_document($doc_id);
    if (!$doc) return null;
    if (!in_array($doc['status'], ['waiting_signatures', 'signed_by_1'], true)) return null;

    $pages = array_map(fn($p) => [
        'num'    => $p['num'],
        'width'  => $p['width'],
        'height' => $p['height'],
        'url'    => '/api/preview.php?doc_id=' . $doc['doc_id'] . '&page=' . $p['num'],
    ], $doc['pages']);

    return [
        'doc_id'   => $doc['doc_id'],
        'status'   => $doc['status'],
        'p1_label' => $doc['p1_label'],
        'p2_label' => $doc['p2_label'],
        'pages'    => $pages,
        'zones'    => $doc['zones'],
        'signed_1' => $doc['signed_1'],
        'signed_2' => $doc['signed_2'],
    ];
}

// === Nettoyage opportuniste : ~5 % des requêtes déclenchent un cleanup ===
if (random_int(1, 20) === 1) {
    @cleanup_storage();
}
