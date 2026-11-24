# Security Policy

## Supported versions

Only the latest release of the Firefox add-on, the Android app and the sync server receives security fixes.

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Use GitHub's private reporting instead:
[**Report a vulnerability**](https://github.com/NorbertDudek/pouch/security/advisories/new)

Please include:

- the affected component (add-on, sync server, Android app) and version,
- steps to reproduce or a proof of concept,
- the impact you expect.

You will get a reply within 7 days. Once the issue is confirmed, a fix will be released as soon as possible
and you will be credited in the release notes (unless you prefer otherwise).

## Hardening tips for the sync server

- Serve it over **HTTPS** only.
- Use a long, random token (32+ characters).
- Keep the SQLite database outside the public web root if your hosting allows it.
