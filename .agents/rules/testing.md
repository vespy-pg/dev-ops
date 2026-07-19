# Testing And Verification

Use risk-tiered verification. Choose the smallest checks that protect the changed behavior, then report what was not run.

## Docs / Specs / Rules Only

- No deploy or app test suite required.
- Run structural validation where useful: file existence, symlink checks, and grep/find sanity checks.

## Shell Script Changes

Run relevant checks for touched scripts:

- `bash -n <script>`
- focused dry-run/help/argument-validation checks when the script supports them.
- ShellCheck when available and scoped to touched scripts.

Do not run scripts that deploy, restart services, mutate filesystem state, install packages, or touch production unless explicitly approved.

## High-Risk Changes

For production deploy, TLS, Apache/PHP-FPM, database, sudo/SSH, secrets, and broad shared deployment behavior:

- run stricter static checks,
- inspect call paths and default env values,
- verify target separation,
- ask for explicit approval before live execution,
- report rollback or manual recovery assumptions when relevant.

## Remote Verification

- Prefer read-only checks first.
- When sudo is needed, verify temporary sudo with `sudo -n true`.
- Report remote commands that were not run because they require approval or elevated access.
