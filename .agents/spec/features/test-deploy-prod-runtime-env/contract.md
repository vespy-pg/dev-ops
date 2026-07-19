# Contract

## Current Behavior

Test deploy and init wrappers target the test instance:

- `APP_NAME=dinpanel-test`
- `APP_BASE_DIR=/var/www/dinpanel-test`
- common script environment argument: `test`

The wrappers default Symfony runtime to:

- `APP_RUNTIME_ENV=prod`

This prevents Symfony Runtime from loading `env/.api.env.test`, which belongs to automated tests and may contain Docker-only hostnames such as `postgres`.

## Operational Impact

Deploying the test instance should use the test app directory and test database env files copied from `scripts/deploy/dinpanel/test`, but console commands such as Doctrine migrations and cache warmup run with Symfony `--env=prod`.

## Boundaries

This does not change production deploy behavior, database credentials, host configuration, Apache configuration, or Doctrine migration execution policy.
