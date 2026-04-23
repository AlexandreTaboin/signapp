<?php
// /api/set_zones.php
require_once __DIR__ . '/../config/config.php';
require_role('pc');

$input = json_decode(file_get_contents('php://input'), true);
if (!is_array($input)) json_response(['success' => false, 'error' => 'JSON invalide'], 400);
error_log('SET_ZONES dbg: recv=' . substr($input['csrf_token'] ?? 'NULL', 0, 10) . ' sess=' . substr($_SESSION['csrf_token'] ?? 'NULL', 0, 10) . ' sid=' . session_id() . ' role=' . ($_SESSION['user']['role'] ?? 'none'));
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

// Validation & nettoyage des zones
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
