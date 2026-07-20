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

TLS defaults use explicit test wrapper domains that currently resolve to the test host:

- `test.dinpanel.com`
- `api.test.dinpanel.com`

`www.test.dinpanel.com` is intentionally excluded from the default because it currently has no DNS record. Operators may opt in with `TLS_DOMAINS` after DNS exists.

TLS automation must reconcile the existing named certificate to the requested `TLS_DOMAINS` set. This allows a previous `test.dinpanel.com` lineage that included `www.test.dinpanel.com` to be renewed without the DNS-missing hostname.

During init, after TLS automation issues or renews a certificate, Apache vhosts are regenerated, config-tested, and reloaded before the script continues. This prevents a successful cert issuance from leaving the active test site with only HTTP vhosts.

When a certificate exists, common init/deploy scripts generate HTTPS vhosts only for names present in `TLS_DOMAINS`. HTTP vhosts may still exist for redirect and ACME handling, but Apache should not bind a `:443` `ServerName` to a certificate that was not requested for that name.

Optional HTTPS vhost blocks are concatenated with explicit newline separators. This preserves valid Apache syntax when more than one TLS-backed name is enabled, because Bash command substitution strips trailing newlines from heredoc output before `+=` appends the next block.

## Boundaries

This does not change production deploy behavior, database credentials, host configuration, Apache configuration, or Doctrine migration execution policy.
