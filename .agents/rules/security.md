# Security And Access Rules

## Credentials

- Never commit private SSH keys, passwords, API tokens, database passwords, TLS private keys, `.agents/.env`, or runtime env files.
- Public keys may be kept local unless there is a clear reason to version them.
- Prefer dedicated technical users and least-privilege access.
- Temporary elevated access is preferred for remote administration.

## SSH And Sudo

- Verify access with read-only commands first, such as `whoami`, `hostname`, `id`, and `sudo -n true`.
- Do not alter sudoers, authorized keys, firewall, or SSH daemon configuration without explicit user approval.
- If server work requires sudo and `sudo -n` is unavailable, tell the user exactly why sudo is needed, ask them to grant temporary sudo, and continue from the current context after access is available.
- Do not use SSH access to manually patch files in `/home/pawel/dev-ops`; make those changes locally in `vespy-dev-ops` and rely on the server's git-based update flow.
- After privileged work, recommend or verify revocation when the user asked for time-limited access.

## Sensitive Output

- Treat logs, env files, database dumps, command histories, and deployment output as potentially sensitive.
- Redact secrets in user-facing summaries.
- Store copied diagnostic output under `.agents/var/logs/` or `.agents/var/tmp/`, which are git-ignored.
