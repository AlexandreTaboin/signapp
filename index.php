<?php
// /index.php
// Routeur principal — redirige selon le rôle

require_once __DIR__ . '/config/config.php';

if (empty($_SESSION['user'])) {
    header('Location: /login.php');
    exit;
}

$role = $_SESSION['user']['role'] ?? '';
if ($role === 'pc') {
    header('Location: /pc/index.php');
} elseif ($role === 'tablet') {
    header('Location: /tablet/index.php');
} else {
    session_destroy();
    header('Location: /login.php');
}
exit;
