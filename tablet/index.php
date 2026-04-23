<?php
// /tablet/index.php
require_once __DIR__ . '/../config/config.php';
require_role('tablet');
$csrf = generate_csrf_token();
?>
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <title>Tablette Signature</title>
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
    <link rel="stylesheet" href="/assets/css/style.css">
    <link rel="stylesheet" href="/assets/css/tablet.css">
</head>
<body class="tablet-body">

<!-- Écran 1 : Liste des documents en attente -->
<div id="list-screen" class="list-screen">
    <header class="list-header">
        <h1>📋 Documents à signer</h1>
        <div class="list-count"><span id="list-count">0</span> document(s) en attente</div>
    </header>
    <div id="documents-list" class="documents-list">
        <!-- Peuplé dynamiquement -->
    </div>
    <div id="empty-state" class="empty-state hidden">
        <div class="big-icon">⏳</div>
        <h2>Aucun document en attente</h2>
        <p>Le gestionnaire va envoyer de nouvelles fiches à signer.</p>
    </div>
</div>

<!-- Écran 2 : Lecture du document -->
<div id="reading-screen" class="reading-screen hidden">
    <header class="reading-header">
        <button type="button" id="btn-back-list" class="btn btn-ghost">← Retour</button>
        <h2 id="reading-title">Document</h2>
        <div class="page-indicator">
            Page <span id="page-current">1</span> / <span id="page-total">1</span>
        </div>
    </header>

    <div class="reading-viewport" id="reading-viewport">
        <div class="reading-page-wrapper" id="reading-page-wrapper">
            <img id="reading-page-img" src="" alt="Page">
        </div>
    </div>

    <footer class="reading-footer">
        <button type="button" id="btn-prev-page" class="btn btn-nav">◀ Précédent</button>
        <div class="zoom-controls">
            <button type="button" id="btn-zoom-out" class="btn">−</button>
            <button type="button" id="btn-zoom-reset" class="btn">100%</button>
            <button type="button" id="btn-zoom-in" class="btn">+</button>
        </div>
        <button type="button" id="btn-start-signing" class="btn btn-sign">✍ Signer le document</button>
        <button type="button" id="btn-next-page" class="btn btn-nav">Suivant ▶</button>
    </footer>
</div>

<!-- Écran 3 : Signature (l'ancien document-screen, renommé) -->
<div id="document-screen" class="hidden">
    <header class="tablet-header">
        <button type="button" id="btn-back" class="btn btn-ghost btn-back">← Revenir à la lecture</button>
        <h2 id="doc-title">Document</h2>
        <div id="current-signer-banner"></div>
    </header>

    <main id="doc-content">
        <div id="pages-container"></div>
        <div id="signature-panel" class="signature-panel hidden">
            <h3 id="sig-zone-label">Signez ici</h3>
            <canvas id="signature-canvas"></canvas>
            <div class="sig-actions">
                <button type="button" id="btn-clear" class="btn btn-ghost">Effacer</button>
                <button type="button" id="btn-validate" class="btn btn-primary">✓ Valider ma signature</button>
            </div>
        </div>
    </main>
</div>

<meta name="csrf-token" content="<?= htmlspecialchars($csrf, ENT_QUOTES) ?>">
<div id="toast" class="toast hidden"><div class="toast-icon">✓</div><div class="toast-text">Signature enregistrée</div></div>
<script src="/assets/js/signature_canvas.js"></script>
<script src="/assets/js/tablet.js"></script>
</body>
</html>
