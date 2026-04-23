<?php
// /api/send_to_tablet.php
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

// Optionnel : passer tous les autres docs actifs en statut annulé pour n'avoir qu'un doc actif
// Ici on laisse simple : la tablette prend le plus récent en waiting

$doc['status'] = 'waiting_signatures';
$doc['sent_at'] = time();
save_document($doc_id, $doc);

json_response(['success' => true]);
