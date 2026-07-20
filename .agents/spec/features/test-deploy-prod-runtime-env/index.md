# Test Deploy Prod Runtime Env

Date: 2026-07-20
Status: Implemented
Scope: Test deploy/init wrappers for `dinpanel-test`.

## Objective

Keep the test deployment target separate from production while running Symfony with the production runtime environment. The `test` Symfony environment loads `.api.env.test`, which is intended for automated tests and Docker-style database hostnames.

## Read This First

- [Contract](contract.md)
- [Test Status](test-status.md)
- [Decisions](decisions.md)
- [Implementation Log](implementation-log.md)

## Checklist

- [x] Confirm failure source.
- [x] Set test deploy wrapper default `APP_RUNTIME_ENV=prod`.
- [x] Set test init wrapper default `APP_RUNTIME_ENV=prod`.
- [x] Enable HTTPS redirect and TLS automation by default for the test target.
- [x] Limit test TLS default domains to DNS-backed names.
- [x] Reconcile existing named TLS certificates to the requested domain set.
- [x] Reload Apache after init creates TLS-backed vhosts.
- [x] Generate HTTPS vhosts only for names covered by `TLS_DOMAINS`.
- [x] Keep concatenated optional HTTPS vhost blocks separated by explicit newlines.
- [x] Verify shell syntax.
- [x] Update spec registry.

## Current Status

`scripts/deploy/dinpanel/test/deploy.sh` and `scripts/deploy/dinpanel/test/init.sh` default `APP_RUNTIME_ENV` to `prod`, enable TLS automation/HTTPS redirects, request TLS only for `test.dinpanel.com` and `api.test.dinpanel.com` by default, while keeping `APP_NAME=dinpanel-test`, `APP_BASE_DIR=/var/www/dinpanel-test`, and the common deploy environment argument as `test`. Common Apache generation now adds explicit separators between optional HTTPS vhost blocks so multiple TLS-backed names cannot be written as a single malformed Apache directive line.
