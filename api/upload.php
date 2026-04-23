<?php
set_time_limit(600);
ini_set('memory_limit', '1024M');

// /api/upload.php
require_once __DIR__ . '/../config/config.php';
require_role('pc');

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    json_response(['success' => false, 'error' => 'Méthode non autorisée'], 405);
}
if (!verify_csrf_token($_POST['csrf_token'] ?? null)) {
    json_response(['success' => false, 'error' => 'CSRF invalide'], 403);
}

// === Validation du fichier ===
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

// Vérifie signature PDF (%PDF-)
$fh = fopen($file['tmp_name'], 'rb');
$magic = fread($fh, 5);
fclose($fh);
if ($magic !== '%PDF-') {
    json_response(['success' => false, 'error' => 'Fichier PDF invalide'], 400);
}

// === Validation noms ===
$p1f = sanitize_name($_POST['p1_firstname'] ?? '');
$p1l = sanitize_name($_POST['p1_lastname'] ?? '');
$p2f = sanitize_name($_POST['p2_firstname'] ?? '');
$p2l = sanitize_name($_POST['p2_lastname'] ?? '');
if (!$p1f || !$p1l || !$p2f || !$p2l) {
    json_response(['success' => false, 'error' => 'Tous les noms sont requis'], 400);
}

// === Création du document ===
$doc_id = bin2hex(random_bytes(16));
$pdf_dest = PDF_PATH . '/' . $doc_id . '.pdf';
if (!move_uploaded_file($file['tmp_name'], $pdf_dest)) {
    json_response(['success' => false, 'error' => 'Impossible de sauvegarder le PDF'], 500);
}
chmod($pdf_dest, 0644);

// === Conversion PDF → PNG pour prévisualisation ===
$preview_dir = PREVIEW_PATH . '/' . $doc_id;
if (!is_dir($preview_dir)) mkdir($preview_dir, 0755, true);

$pages = [];
$conversion_error = null;

// === Conversion PDF → PNG via Ghostscript direct ===
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

// === Création session document ===
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
