<?php
// /api/preview.php
// Servir les images de prévisualisation sécurisées
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
