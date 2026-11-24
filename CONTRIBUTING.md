# Contributing to Pouch

Thanks for your interest in improving Pouch! 🎉

## Reporting bugs and requesting features

- Search [existing issues](https://github.com/NorbertDudek/pouch/issues) first.
- Use the **Bug report** or **Feature request** template — it asks for the details needed to help you quickly.
- Security problems: **do not** open a public issue — see [SECURITY.md](SECURITY.md).

## Development setup

| Part | Requirements | Quick start |
|------|--------------|-------------|
| `extension/` | Firefox 140+, Node.js (for `web-ext`) | `npm install && npm start` (repo root) |
| `server/` | PHP 8.0+ with `pdo_sqlite` | `php -S localhost:8080` |
| `android/` | RAD Studio (Delphi) with the Android platform | open `android/Pouch.dpr` |

## Pull requests

1. Fork the repository and create a branch from `main` (`feat/short-name` or `fix/short-name`).
2. Keep changes focused — one feature or fix per pull request.
3. Make sure checks pass locally:
   - `npm run lint` in the repository root
   - `php -l` on changed PHP files
4. Update `CHANGELOG.md` under **Unreleased** if the change is user-visible.
5. Open the pull request and fill in the template.

## Code style

- Plain JavaScript (no frameworks, no external libraries) — keep the add-on lightweight.
- Do not add permissions to `manifest.json` unless absolutely necessary, and explain why in the PR.
- Never commit secrets: `server/config.php` and database files are ignored on purpose.
- Formatting follows [`.editorconfig`](.editorconfig).

## Commit messages

Short imperative subject line, e.g. `Add pagination to the full-tab view`.
[Conventional Commits](https://www.conventionalcommits.org/) prefixes (`feat:`, `fix:`, `docs:`) are welcome.

## License

By contributing, you agree that your contributions will be licensed under the [Mozilla Public License 2.0](LICENSE).
