# Ops And Deployment Rules

## Scope

These rules apply to deploy, init, TLS, Apache, PHP-FPM, service, filesystem-layout, package, release, rollback, and server-maintenance work.

## Production Safety

- Before any production-affecting command, identify the exact host, user, script path, app target, environment, and intended effect.
- Do not run production deploy/init/TLS/service/package commands without explicit user approval for that action.
- Prefer read-only diagnostics first: inspect files, service status, logs, current symlinks, disk space, and environment state before proposing changes.
- Preserve release rollback paths and shared directories.
- Do not edit files directly in live release directories unless the user explicitly asks for an emergency hotfix.

## Script Standards

- Shell scripts must use `#!/usr/bin/env bash` and `set -Eeuo pipefail`.
- Validate arguments and reject empty critical values.
- Quote variable expansions unless shell word splitting is intentional.
- Keep deploy scripts idempotent where practical.
- Make environment defaults explicit near the top of the script.
- Refuse ambiguous or dangerous targets, especially test scripts pointing at production paths.
- Prefer small helper functions for repeated validation or mutation logic.

## Environment And Secrets

- Runtime env files and secrets are not committed.
- Env examples may document keys but must use placeholder values.
- When modifying env handling, preserve existing local override behavior.
- Do not print secrets in logs or final responses.

## Remote Work

- Use the `codex` SSH account for diagnostics unless a task explicitly requires another account.
- Use `sudo -n` checks to confirm whether temporary sudo is currently available; do not ask for persistent broad sudo.
- If sudo is unavailable and required, tell the user what privileged command or file access is needed, ask them to grant temporary sudo, and continue the same task after sudo is granted.
- Do not modify `/home/pawel/dev-ops` directly over SSH. Server-side `dev-ops` is managed from git; make changes locally in this `vespy-dev-ops` repository and let the server update through the normal git/deploy flow.
