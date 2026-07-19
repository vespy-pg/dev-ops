# Vespy Dev Ops Agent Rules

## Rule Hierarchy

1. This file is the always-loaded router and safety layer for this repository.
2. Topic rules in `.agents/rules/*.md` are mandatory when their trigger applies.
3. More specific rules beat broader rules.
4. Rule changes must not weaken production, security, deployment, database, spec, or test discipline.
5. Before changing rules, check `.github/copilot/instructions/` if present and reject any change that conflicts with those instructions.

## Mandatory Topic Loading

- Feature/spec work: read `.agents/rules/specs.md`.
- Deploy, init, TLS, Apache, PHP-FPM, service, filesystem-layout, or release-script work: read `.agents/rules/ops.md`.
- SSH, sudo, credentials, secrets, keys, production access, or remote-server work: read `.agents/rules/security.md`.
- Database, SQL, migration, schema-permission, backup, restore, or data-fix work: read `.agents/rules/database.md`.
- Tests/verification decisions: read `.agents/rules/testing.md`.
- Subagent decisions: read `.agents/rules/subagents.md`.

## Non-Negotiable Safety Rules

- Treat production hosts and production deploy scripts as high-risk by default.
- Do not run production deploy, init, TLS, service restart, package install, destructive filesystem, or database mutation commands without explicit user approval for that action.
- Never commit private keys, credentials, server tokens, `.agents/.env`, runtime env files, logs with secrets, or generated dumps.
- Do not modify a database directly. Do not execute `INSERT`, `UPDATE`, `DELETE`, DDL, destructive SQL, migration application commands, backup restore, or schema permission changes. Generate scripts under `.agents/var/sql/` for user review instead.
- Use parameterized queries for any read-only database exploration.
- Deployment scripts must stay repeatable, fail-fast, and explicit about the target environment.
- Production/test target separation must be preserved. Test deploy paths must refuse production app targets.
- New non-trivial ops work must have/update a root `.agents/spec` spec before implementation continues.
- Do not update only `implementation-log.md`; compact spec files must reflect the current truth after implementation batches.

## Spec Entry Point

- Before feature or ops workflow changes, check `.agents/spec/index.md`.
- Read the feature `index.md` first, then only linked content files needed for the task.
- Keep `implementation-log.md` out of the default read path unless debugging history/regressions.

## Working Files

- Use `.agents/var/` for AI-generated working files.
- Non-project working files outside structured feature-spec directories must start with a datetime prefix, preferably `Ymd_His-`.
- Structured feature-spec directories may use stable filenames: `index.md`, `contract.md`, `test-status.md`, `decisions.md`, `implementation-log.md`.
- Generated SQL scripts go under `.agents/var/sql/`.
- Temporary diagnostics, logs, and copied remote output go under `.agents/var/tmp/` or `.agents/var/logs/`.
- Do not inspect archived/generated artifacts by default; open them only when a task explicitly needs that historical data.

## Default Verification

- Use risk-tiered verification from `.agents/rules/testing.md`.
- Docs/spec/rules-only changes need structural validation, not deploy or app test suites.
- Report tests/checks not run when they would normally be relevant.
