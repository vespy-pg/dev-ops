# Contract

## Current Behavior

Init requires pre-existing ops env files before it begins package installation, service configuration, source checkout, or database bootstrap.

Defaults:

- `REQUIRED_OPS_ENV_FILES=".api.env .web.env"`
- DB env file: `${DB_ENV_FILE}`, default `.api.env`

The DB env file must include:

- `DB_HOST`
- `DB_PORT`
- `DB_NAME`
- `DB_USER` or `DB_USERNAME`
- `DB_PASSWORD`

`prepare_ops_env_files` no longer creates env files from `*.env.example`; it fails if a required target is missing.

Database bootstrap uses the password from the prepared DB env file. It does not generate a new DB password.

## Operational Impact

Operators must prepare env files explicitly before running init. This prevents accidental placeholder envs and prevents init from silently rotating app-side DB credentials away from an existing PostgreSQL role password.

## Boundaries

This does not execute database changes and does not repair existing PostgreSQL role passwords. Existing role/password mismatches need a separately reviewed DB command.
