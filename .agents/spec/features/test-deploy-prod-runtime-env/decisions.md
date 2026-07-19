# Decisions

## Durable Decisions

- `test` in the deploy script path means the staging/test deployment target, not Symfony's automated-test runtime environment.
- Test deployment should default to Symfony `prod` runtime unless explicitly overridden with `APP_RUNTIME_ENV`.
- Test deployment should use HTTPS by default, with its own certificate for test/API/www test domains.
