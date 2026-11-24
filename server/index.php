<?php
// Sync server for the Pouch add-on. Requires PHP 8.0+ with the pdo_sqlite extension.
//
// Protocol (everything at one address, X-Schowek-Token header on every request):
//   GET  ?ping=1    -> {ok, app, version}                 connection and token test
//   GET  ?since=N   -> {items, cursor, more}              records changed after revision N
//   POST {items}    -> {ok, accepted}                     store changes from a device
//
// Every accepted change gets the next revision number (rev) — that is the cursor,
// so device clocks have no effect on what gets pulled. Conflicts are resolved
// by updatedAt: the newer version of a record wins. Deleted records stay in the
// database as "tombstones" (deletedAt), so the deletion reaches every device.

declare(strict_types=1);

const API_VERSION = 1;
const PAGE_SIZE = 500;
const MAX_PUSH_ITEMS = 200;
const MAX_BODY_BYTES = 8 * 1024 * 1024;
const MAX_URL_LENGTH = 4096;
const MAX_TITLE_LENGTH = 1000;
const MAX_FAVICON_LENGTH = 65536;

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');
// The add-on connects from outside the server's origin; access is protected by the token anyway.
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type, X-Schowek-Token');
header('Access-Control-Max-Age: 86400');

function respond(int $status, array $data): void
{
    http_response_code($status);
    echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

function fail(int $status, string $message): void
{
    respond($status, ['ok' => false, 'error' => $message]);
}

set_exception_handler(static function (Throwable $error): void {
    error_log('Pouch: ' . $error->getMessage());
    fail(500, 'Server error.');
});

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

if ($method === 'OPTIONS') {
    http_response_code(204);
    exit;
}

$config = require __DIR__ . '/config.php';
$token = (string) ($config['token'] ?? '');

if (strlen($token) < 16) {
    fail(503, 'Server is not configured: set a token (at least 16 characters) in config.php.');
}

if (!hash_equals($token, (string) ($_SERVER['HTTP_X_SCHOWEK_TOKEN'] ?? ''))) {
    fail(401, 'Invalid token.');
}

/**
 * Default database location: data/schowek-<random name>.sqlite. The directory is
 * reachable over the web, so three things protect it at once: .htaccess (Apache),
 * an empty index.html (no directory listing) and an unguessable file name
 * (which also works on nginx, where .htaccess is ignored).
 */
function defaultDatabasePath(): string
{
    $directory = __DIR__ . '/data';
    if (!is_dir($directory)) {
        mkdir($directory, 0700, true);
    }
    if (!is_file($directory . '/.htaccess')) {
        @file_put_contents($directory . '/.htaccess', "Require all denied\n");
    }
    if (!is_file($directory . '/index.html')) {
        @file_put_contents($directory . '/index.html', '');
    }
    $nameFile = $directory . '/name.php';
    if (!is_file($nameFile)) {
        file_put_contents($nameFile, "<?php return '" . bin2hex(random_bytes(16)) . "';\n", LOCK_EX);
    }

    return $directory . '/schowek-' . (require $nameFile) . '.sqlite';
}

function database(?string $path): PDO
{
    $path ??= defaultDatabasePath();

    $pdo = new PDO('sqlite:' . $path, null, null, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    ]);
    $pdo->exec('PRAGMA busy_timeout = 5000');
    $pdo->exec(
        'CREATE TABLE IF NOT EXISTS items (
            id         TEXT PRIMARY KEY,
            url        TEXT NOT NULL,
            title      TEXT NOT NULL,
            favicon    TEXT NOT NULL DEFAULT \'\',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER,
            rev        INTEGER NOT NULL
        )'
    );
    $pdo->exec('CREATE INDEX IF NOT EXISTS items_rev ON items (rev)');

    return $pdo;
}

function timestamp(mixed $value): ?int
{
    if (!is_int($value) && !is_float($value)) {
        return null;
    }
    $number = (int) $value;

    return $number > 0 ? $number : null;
}

/** Validates a record from a device; returns null if it is invalid. */
function validItem(mixed $raw): ?array
{
    if (!is_array($raw)) {
        return null;
    }
    $id = $raw['id'] ?? null;
    $url = $raw['url'] ?? null;
    $title = $raw['title'] ?? null;
    $favicon = $raw['favicon'] ?? '';
    $createdAt = timestamp($raw['createdAt'] ?? null);
    $updatedAt = timestamp($raw['updatedAt'] ?? null);
    $deletedAt = ($raw['deletedAt'] ?? null) === null ? null : timestamp($raw['deletedAt']);

    if (!is_string($id) || !preg_match('/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i', $id)) {
        return null;
    }
    if (!is_string($url) || strlen($url) > MAX_URL_LENGTH || !preg_match('#^https?://#i', $url)) {
        return null;
    }
    if (!is_string($title) || $createdAt === null || $updatedAt === null) {
        return null;
    }
    if (($raw['deletedAt'] ?? null) !== null && $deletedAt === null) {
        return null;
    }
    if (
        !is_string($favicon)
        || strlen($favicon) > MAX_FAVICON_LENGTH
        || !preg_match('#^(https?://|data:image/)#i', $favicon)
    ) {
        $favicon = '';
    }

    return [
        'id' => strtolower($id),
        'url' => $url,
        'title' => mb_substr($title, 0, MAX_TITLE_LENGTH),
        'favicon' => $favicon,
        'created_at' => $createdAt,
        'updated_at' => $updatedAt,
        'deleted_at' => $deletedAt,
    ];
}

if ($method === 'GET' && isset($_GET['ping'])) {
    respond(200, ['ok' => true, 'app' => 'schowek', 'version' => API_VERSION]);
}

$pdo = database($config['database'] ?? null);

if ($method === 'GET') {
    $since = max(0, (int) ($_GET['since'] ?? 0));
    $query = $pdo->prepare('SELECT * FROM items WHERE rev > ? ORDER BY rev LIMIT ' . (PAGE_SIZE + 1));
    $query->execute([$since]);
    $rows = $query->fetchAll();

    $more = count($rows) > PAGE_SIZE;
    $rows = array_slice($rows, 0, PAGE_SIZE);
    $cursor = $rows ? (int) $rows[count($rows) - 1]['rev'] : $since;

    $items = array_map(static fn (array $row): array => [
        'id' => $row['id'],
        'url' => $row['url'],
        'title' => $row['title'],
        'favicon' => $row['favicon'],
        'createdAt' => (int) $row['created_at'],
        'updatedAt' => (int) $row['updated_at'],
        'deletedAt' => $row['deleted_at'] === null ? null : (int) $row['deleted_at'],
    ], $rows);

    respond(200, ['ok' => true, 'items' => $items, 'cursor' => $cursor, 'more' => $more]);
}

if ($method === 'POST') {
    $body = file_get_contents('php://input', false, null, 0, MAX_BODY_BYTES + 1);
    if ($body === false || strlen($body) > MAX_BODY_BYTES) {
        fail(413, 'Request too large.');
    }
    $payload = json_decode($body, true);
    $incoming = is_array($payload) ? ($payload['items'] ?? null) : null;
    if (!is_array($incoming) || count($incoming) > MAX_PUSH_ITEMS) {
        fail(400, 'Invalid request.');
    }

    $items = [];
    foreach ($incoming as $raw) {
        $item = validItem($raw);
        if ($item === null) {
            fail(400, 'Invalid record.');
        }
        $items[] = $item;
    }

    // BEGIN IMMEDIATE: only one writer at a time assigns revision numbers.
    $pdo->exec('BEGIN IMMEDIATE');
    try {
        $rev = (int) $pdo->query('SELECT COALESCE(MAX(rev), 0) FROM items')->fetchColumn();
        $upsert = $pdo->prepare(
            'INSERT INTO items (id, url, title, favicon, created_at, updated_at, deleted_at, rev)
             VALUES (:id, :url, :title, :favicon, :created_at, :updated_at, :deleted_at, :rev)
             ON CONFLICT (id) DO UPDATE SET
                url = excluded.url,
                title = excluded.title,
                favicon = excluded.favicon,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at,
                deleted_at = excluded.deleted_at,
                rev = excluded.rev
             WHERE excluded.updated_at > items.updated_at'
        );
        $accepted = 0;
        foreach ($items as $item) {
            $upsert->execute($item + ['rev' => ++$rev]);
            $accepted += $upsert->rowCount();
        }
        $pdo->exec('COMMIT');
    } catch (Throwable $error) {
        $pdo->exec('ROLLBACK');
        throw $error;
    }

    respond(200, ['ok' => true, 'accepted' => $accepted]);
}

header('Allow: GET, POST, OPTIONS');
fail(405, 'Method not supported.');
