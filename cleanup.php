<?php
// /cleanup.php
// Script de nettoyage lancé par cron
require_once __DIR__ . '/config/config.php';

if (!function_exists('cleanup_storage')) {
    echo date('[Y-m-d H:i:s] ') . 'ERROR: cleanup_storage() not found' . PHP_EOL;
    exit(1);
}

$stats = cleanup_storage();
echo date('[Y-m-d H:i:s] ') . json_encode($stats) . PHP_EOL;
