<?php
// /api/sign.php
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

// Validation base64 PNG
if (!preg_match('/^data:image\/png;base64,([A-Za-z0-9+\/=]+)$/', $b64, $m)) {
    json_response(['success' => false, 'error' => 'Signature invalide'], 400);
}
$bin = base64_decode($m[1], true);
if ($bin === false || strlen($bin) < 100 || strlen($bin) > 2 * 1024 * 1024) {
    json_response(['success' => false, 'error' => 'Données signature invalides'], 400);
}
// Vérifier signature PNG
if (substr($bin, 0, 8) !== "\x89PNG\r\n\x1a\n") {
    json_response(['success' => false, 'error' => 'Format PNG invalide'], 400);
}

// Sauvegarder signature
$sig_file = SIGNATURES_PATH . '/' . $doc_id . '_p' . $person . '.png';
if (file_put_contents($sig_file, $bin) === false) {
    json_response(['success' => false, 'error' => 'Erreur sauvegarde signature'], 500);
}
chmod($sig_file, 0644);

// Mise à jour document
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

// Transition statut
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
    // cas où P2 signe avant P1 (non prévu mais on gère)
    $doc['status'] = 'signed_by_1'; // on garde un état intermédiaire
}

save_document($doc_id, $doc);
json_response(['success' => true, 'status' => $doc['status']]);


// === Génération du PDF final avec signatures ===
function generate_final_pdf(array $doc): ?string {
    require_once LIBS_PATH . '/tcpdf/tcpdf.php';
    require_once LIBS_PATH . '/FPDI/src/autoload.php';

    try {
        // Classe étendue : TCPDF + FPDI
        $pdf = new \setasign\Fpdi\Tcpdf\Fpdi();
        $pdf->setPrintHeader(false);
        $pdf->setPrintFooter(false);
        $pdf->SetAutoPageBreak(false);
        $pdf->SetMargins(0, 0, 0);

$src_pdf = PDF_PATH . '/' . $doc['doc_id'] . '.pdf';

// Décompresser le PDF pour compatibilité FPDI (gère PDF 1.5+ avec object streams)
$compat_pdf = sys_get_temp_dir() . '/fpdi_' . $doc['doc_id'] . '.pdf';
$cmd = sprintf(
    'gs -q -dNOPAUSE -dBATCH -dSAFER -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 -sOutputFile=%s %s 2>&1',
    escapeshellarg($compat_pdf),
    escapeshellarg($src_pdf)
);
exec($cmd, $out, $rc);
if ($rc !== 0 || !is_file($compat_pdf)) {
    error_log('GS decompress failed: ' . implode("\n", $out));
    $compat_pdf = $src_pdf; // fallback
}

$pageCount = $pdf->setSourceFile($compat_pdf);

        for ($pageNo = 1; $pageNo <= $pageCount; $pageNo++) {
            $tplId = $pdf->importPage($pageNo);
            $size = $pdf->getTemplateSize($tplId);
            $orientation = ($size['width'] > $size['height']) ? 'L' : 'P';
            $pdf->AddPage($orientation, [$size['width'], $size['height']]);
            $pdf->useTemplate($tplId, 0, 0, $size['width'], $size['height']);

            // Incruster signatures pour cette page
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

                // Label texte en dessous
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
    } catch (\Throwable $e) { error_log("SIGN PDF ERROR: " . $e->getMessage() . " @ " . $e->getFile() . ":" . $e->getLine() . "\n" . $e->getTraceAsString());
        error_log('PDF generation error: ' . $e->getMessage());
        return null;
    }
}
