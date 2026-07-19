# Contract

## Current Behavior

Test deploy and init wrappers target the test instance:

- `APP_NAME=dinpanel-test`
- `APP_BASE_DIR=/var/www/dinpanel-test`
- common script environment argument: `test`

The wrappers default Symfony runtime to:

- `APP_RUNTIME_ENV=prod`
- `FORCE_HTTPS_REDIRECT=1`
- `ENABLE_TLS_AUTOMATION=1`

This prevents Symfony Runtime from loading `env/.api.env.test`, which belongs to automated tests and may contain Docker-only hostnames such as `postgres`.
It also ensures the test site gets its own Let's Encrypt certificate and HTTP redirects instead of falling through to the production HTTPS vhost.

## Operational Impact

Deploying the test instance should use the test app directory and test database env files copied from `scripts/deploy/dinpanel/test`, but console commands such as Doctrine migrations and cache warmup run with Symfony `--env=prod`.

TLS defaults use the common script's derived domains for test:

- `test.dinpanel.com`
- `www.test.dinpanel.com`
- `api.test.dinpanel.com`

## Boundaries

This does not change production deploy behavior, database credentials, host configuration, Apache configuration, or Doctrine migration execution policy.
