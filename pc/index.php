<?php
// /pc/index.php
require_once __DIR__ . '/../config/config.php';
require_role('pc');
$csrf = generate_csrf_token();
$user = $_SESSION['user'];
?>
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <title>Dashboard PC — Signature</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link rel="stylesheet" href="/assets/css/style.css">
    <link rel="stylesheet" href="/assets/css/pc.css">
</head>
<body>
<header class="top-bar">
    <h1>📄 Signature Électronique — Gestionnaire</h1>
    <div class="user-info">
        <span><?= htmlspecialchars($user['display_name']) ?></span>
        <a href="/logout.php" class="btn btn-ghost">Déconnexion</a>
    </div>
</header>

<main class="container">
    <!-- Étape 1 : Upload -->
    <section id="step-upload" class="card">
        <h2>Étape 1 — Nouveau document</h2>
        <form id="upload-form">
            <input type="hidden" name="csrf_token" value="<?= htmlspecialchars($csrf) ?>">

            <div class="form-row">
                <label>
                    Fichier PDF (max 10 Mo)
                    <input type="file" name="pdf" accept="application/pdf" required>
                </label>
            </div>

            <div class="form-row-double">
                <fieldset>
                    <legend>Personne 1</legend>
                    <label>Prénom <input type="text" name="p1_firstname" required maxlength="50"></label>
                    <label>Nom <input type="text" name="p1_lastname" required maxlength="50"></label>
                </fieldset>
                <fieldset>
                    <legend>Personne 2</legend>
                    <label>Prénom <input type="text" name="p2_firstname" required maxlength="50"></label>
                    <label>Nom <input type="text" name="p2_lastname" required maxlength="50"></label>
                </fieldset>
            </div>

            <button type="submit" class="btn btn-primary">📤 Charger et continuer</button>
            <div id="upload-status" class="status-msg"></div>
        </form>
    </section>

    <!-- Étape 2 : Placement zones -->
    <section id="step-zones" class="card hidden">
        <h2>Étape 2 — Placer les zones de signature</h2>
        <p class="help">Sélectionnez le signataire actif, puis cliquez sur la page du PDF pour placer sa zone de signature.</p>

        <div class="person-selector">
            <button type="button" class="btn person-btn active" data-person="1">
                ✍️ <span id="label-p1">Personne 1</span>
            </button>
            <button type="button" class="btn person-btn" data-person="2">
                ✍️ <span id="label-p2">Personne 2</span>
            </button>
        </div>

        <div id="pdf-pages" class="pdf-pages"></div>

        <div class="actions-row">
            <button type="button" id="btn-reset-zones" class="btn btn-ghost">🔄 Réinitialiser zones</button>
            <button type="button" id="btn-send-tablet" class="btn btn-primary" disabled>
                📲 Envoyer à la tablette
            </button>
        </div>
    </section>

    <!-- Étape 3 : Suivi -->
    <!-- Suivi des documents envoyés (plusieurs possibles) -->
    <section id="step-tracking" class="card hidden">
        <h2>📋 Documents envoyés à la tablette</h2>
        <div id="tracking-list" class="tracking-list">
            <p class="help">Aucun document en cours.</p>
        </div>
    </section>
</main>

<meta name="csrf-token" content="<?= htmlspecialchars($csrf, ENT_QUOTES) ?>">
<script src="/assets/js/pc.js"></script>

</body>
</html>
