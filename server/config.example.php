<?php
// Copy this file to config.php and adjust it to your existing config format.
// config.php is listed in .gitignore - never commit your real token.
return [
    // Secret token (at least 16 characters). Enter the same one in the add-on options.
    // While it is empty, the server rejects all requests.
    // Generate a random token with:
    //   php -r "echo bin2hex(random_bytes(24));"
    'token' => 'CHANGE-ME-to-a-random-string-of-at-least-32-characters',
	
    // SQLite database file. null = a data/ subdirectory next to this file, with a random
    // file name that cannot be guessed from outside (the directory must be writable
    // by PHP). You can also give your own path — preferably outside the site's
    // public directory, e.g. '/home/user/pouch.sqlite'.
    'database' => null,
];
