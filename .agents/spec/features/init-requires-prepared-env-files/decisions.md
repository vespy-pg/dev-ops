# Decisions

## Durable Decisions

- Init must not create runtime env files from examples.
- Init must not generate database passwords.
- Existing database password mismatches are repaired through explicit reviewed DB commands, not hidden init behavior.
