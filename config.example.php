<?php
/* -----------------------------------------------
   Northport University Project Configuration
   Works for both local & EC2 environments
   -----------------------------------------------
   INSTRUCTIONS:
   Copy this file and rename it to config.php
   Fill in your local database credentials below
   ----------------------------------------------- */
declare(strict_types=1);
error_reporting(E_ALL);
ini_set('display_errors', '1');

/* ---------- PROJECT ROOT ---------- */
/* Adjust if project is in a subfolder (e.g., /UniversityPortal) */
define('PROJECT_ROOT', '/UniversityPortal');

/* ---------- DATABASE CONNECTION ---------- */
/* Replace the values below with your local database credentials */
$DB_HOST = getenv('DB_HOST') ?: '127.0.0.1';
$DB_PORT = (int)(getenv('DB_PORT') ?: 3306);
$DB_USER = getenv('DB_USER') ?: 'your_db_username';   // e.g. 'root' or 'phpuser'
$DB_PASS = getenv('DB_PASS') ?: 'your_db_password';   // XAMPP root password is empty by default
$DB_NAME = getenv('DB_NAME') ?: 'University';

/* ---------- HELPER: Database connection ---------- */
function get_db(): mysqli {
    global $DB_HOST, $DB_PORT, $DB_USER, $DB_PASS, $DB_NAME;
    $mysqli = new mysqli($DB_HOST, $DB_USER, $DB_PASS, $DB_NAME, $DB_PORT);
    if ($mysqli->connect_error) {
        error_log('DB Connection failed: ' . $mysqli->connect_error);
        die('<h2>Database connection failed.</h2>');
    }
    $mysqli->set_charset('utf8mb4');

    /* An UpdateAdmin's writes bypass the policy triggers from migration 012
       (deadlines, holds, prereqs, credit load, timeslot clashes, capacity) --
       session_status() guards this because several AJAX endpoints (get_*.php)
       call get_db() without ever starting a session. */
    if (session_status() === PHP_SESSION_ACTIVE && ($_SESSION['admin_type'] ?? null) === 'update') {
        $mysqli->query('SET @nu_override = 1');
    }

    /* Migration 016's audit triggers write this into AuditLog.ChangedBy.
       Without it every row reads 'root', because every page connects as
       root -- CURRENT_USER() can't see who is logged into the app. */
    if (session_status() === PHP_SESSION_ACTIVE && isset($_SESSION['user_id'])) {
        $mysqli->query('SET @nu_actor = ' . (int)$_SESSION['user_id']);
    }

    return $mysqli;
}

/* ---------- HELPER: Redirect ---------- */
function redirect(string $path): never {
    header('Location: ' . $path, true, 302);
    exit;
}

/* ---------- HELPER: Debug Redirects ---------- */
function debug_redirect(string $path): never {
    echo "Redirecting to: " . htmlspecialchars($path);
    exit;
}
