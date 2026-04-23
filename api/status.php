<?php
// /api/status.php
require_once __DIR__ . '/../config/config.php';

if (empty($_SESSION['user'])) {
    json_response(['success' => false, 'error' => 'Non authentifié'], 403);
}
$role = $_SESSION['user']['role'];

// === Mode tablette ===
if ($role === 'tablet') {

    // Liste des documents en attente
    if (!empty($_GET['list'])) {
        json_response([
            'success' => true,
            'documents' => get_pending_documents_for_tablet(),
        ]);
    }

    // Détail d'un document précis
    if (!empty($_GET['doc_id'])) {
        $doc = get_document_for_tablet($_GET['doc_id']);
        if (!$doc) json_response(['success' => true, 'document' => null]);
        json_response(['success' => true, 'document' => $doc]);
    }

    json_response(['success' => false, 'error' => 'Paramètres manquants'], 400);
}

// === Mode PC : suivi d'un document ===
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
