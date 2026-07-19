# Implementation Log

2026-07-19: Found that failed test releases had `env/.api.env` with `DB_HOST=127.0.0.1`, but Symfony `APP_ENV=test` loaded `env/.api.env.test` with `DB_HOST=postgres`. Updated test deploy/init wrappers to default `APP_RUNTIME_ENV=prod`.
