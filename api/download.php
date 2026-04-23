<?php
// /api/download.php
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

// Marquer comme téléchargé
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
