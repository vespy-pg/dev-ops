# Decisions

## Durable Decisions

- `test` in the deploy script path means the staging/test deployment target, not Symfony's automated-test runtime environment.
- Test deployment should default to Symfony `prod` runtime unless explicitly overridden with `APP_RUNTIME_ENV`.
- Test deployment should use HTTPS by default, with its own certificate for DNS-backed test and API test domains.
- Test TLS automation should only request names that resolve to the test host by default; `www.test.dinpanel.com` stays opt-in until DNS exists.
- Certbot should use `--renew-with-new-domains` for named lineages so an existing test certificate can drop the DNS-missing `www.test.dinpanel.com` SAN.
- Test init should reload Apache immediately after generating TLS-backed vhosts so HTTPS is active even if later init steps fail.
- Common Apache generation should not create HTTPS vhosts for names omitted from `TLS_DOMAINS`.
