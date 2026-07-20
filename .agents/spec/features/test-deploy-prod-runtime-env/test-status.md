# Test Status

## Checks Run

- `bash -n scripts/deploy/dinpanel/test/deploy.sh`
- `bash -n scripts/deploy/dinpanel/test/init.sh`
- `bash -n scripts/deploy/dinpanel/common/init.sh`
- `bash -n scripts/deploy/dinpanel/common/deploy.sh`
- DNS check: `test.dinpanel.com` and `api.test.dinpanel.com` resolve to the test host; `www.test.dinpanel.com` has no A record.
- Local script hardening: certbot now uses `--renew-with-new-domains` for named lineages instead of `--expand`, so existing certificates can drop removed SANs.
- Initial read-only remote check: Apache had no `:443` vhost for `test.dinpanel.com`, so HTTPS fell through to the production `dinpanel.com` certificate.
- Initial read-only remote check: `http://test.dinpanel.com/login` returned `200 OK`, not a redirect.
- Live repair: ACME webroot probe succeeded for `test.dinpanel.com` and `api.test.dinpanel.com`.
- Live repair: `certbot certonly --webroot` issued `test.dinpanel.com` certificate for `test.dinpanel.com` and `api.test.dinpanel.com`.
- Live repair: Apache vhost backup created at `/etc/apache2/sites-available/dinpanel-test.conf.bak.20260719164358`.
- Live repair: Apache configtest passed and Apache was reloaded.
- External verification: `https://test.dinpanel.com/` verifies successfully and returns `200 OK`.
- External verification: `https://api.test.dinpanel.com/` verifies successfully and returns `401 Unauthorized`.
- External verification: HTTP requests to `test.dinpanel.com` and `api.test.dinpanel.com` redirect to HTTPS.

## Checks Not Run

- Test deploy was not executed.
- Production deploy was not executed.
- No full test deploy was executed after the live TLS repair.
- ShellCheck was not run because it is not installed in the local environment.

## Hardening

Live HTTPS is repaired. A future test deploy should preserve it through the updated TLS domain defaults and HTTPS-vhost generation rules.
