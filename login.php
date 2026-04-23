<?php
// /login.php
require_once __DIR__ . '/config/config.php';

$error = '';
$expired = !empty($_GET['expired']);

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    if (!verify_csrf_token($_POST['csrf_token'] ?? null)) {
        $error = 'Jeton CSRF invalide.';
    } else {
        $username = trim($_POST['username'] ?? '');
        $password = $_POST['password'] ?? '';
        $users = USERS;
        if (isset($users[$username]) && password_verify($password, $users[$username]['password_hash'])) {
            session_regenerate_id(true);
            $_SESSION['user'] = [
                'username' => $username,
                'role' => $users[$username]['role'],
                'display_name' => $users[$username]['display_name'],
                'login_time' => time(),
            ];
            $_SESSION['csrf_token'] = bin2hex(random_bytes(32));
            header('Location: /index.php');
            exit;
        } else {
            $error = 'Identifiants incorrects.';
            usleep(500000); // Anti brute-force
        }
    }
}

$csrf = generate_csrf_token();
?>
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <title>Connexion — Signature Électronique</title>
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
    <link rel="stylesheet" href="/assets/css/style.css">
</head>
<body class="login-body">
    <div class="login-box">
        <h1>Signature Électronique</h1>
        <p class="subtitle">Application interne</p>

        <?php if ($expired): ?>
            <div class="alert alert-warning">Votre session a expiré. Veuillez vous reconnecter.</div>
        <?php endif; ?>
        <?php if ($error): ?>
            <div class="alert alert-error"><?= htmlspecialchars($error) ?></div>
        <?php endif; ?>

        <form method="post" autocomplete="off">
            <input type="hidden" name="csrf_token" value="<?= htmlspecialchars($csrf) ?>">
            <label>
                Identifiant
                <input type="text" name="username" required autofocus>
            </label>
            <label>
                Mot de passe
                <input type="password" name="password" required>
            </label>
            <button type="submit" class="btn btn-primary">Se connecter</button>
        </form>
    </div>
</body>
</html>
