# Test Status

## Checks Run

- `bash -n scripts/deploy/dinpanel/test/deploy.sh`
- `bash -n scripts/deploy/dinpanel/test/init.sh`
- Read-only remote check: Apache has no `:443` vhost for `test.dinpanel.com`, so HTTPS falls through to the production `dinpanel.com` certificate.
- Read-only remote check: `http://test.dinpanel.com/login` returns `200 OK`, not a redirect.

## Checks Not Run

- Test deploy was not executed.
- Production deploy was not executed.
- Certbot was not executed.
- Apache reload was not executed.

## Hardening

Live verification requires explicitly running the test deploy on the server.
