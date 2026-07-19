# Database Rules

## Critical Rule

Never attempt to modify any database directly.

Forbidden:

- `INSERT`
- `UPDATE`
- `DELETE`
- DDL
- migration application commands
- backup restore
- schema ownership/permission mutation
- any direct data/schema mutation, even if credentials allow it

Allowed:

- read-only `SELECT` exploration with parameterized queries.
- read-only schema inspection.
- generating scripts for user review.

For modifications:

1. Generate SQL or shell scripts under `.agents/var/sql/`.
2. Present scripts and expected effects to the user.
3. Do not execute modification scripts yourself unless the user explicitly approves that exact execution.

## Environment

- Agent-local settings live in `.agents/.env`.
- See `.agents/.env.example`.
- Read-only DB users are expected for agent exploration.

## Security

- Always use parameterized query syntax.
- Validate user input before using it in commands, scripts, or queries.
- Do not copy database dumps into tracked project paths.
