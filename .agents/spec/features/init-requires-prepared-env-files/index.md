# Init Requires Prepared Env Files

Date: 2026-07-19
Status: Implemented
Scope: `scripts/deploy/dinpanel/common/init.sh`

## Objective

Prevent init from starting system/package/application/database work when required ops env files are missing or incomplete.

## Read This First

- [Contract](contract.md)
- [Test Status](test-status.md)
- [Decisions](decisions.md)
- [Implementation Log](implementation-log.md)

## Checklist

- [x] Add early env file existence validation.
- [x] Require DB connection keys in the DB env file.
- [x] Stop generating DB passwords during init bootstrap.
- [x] Keep env secrets out of git.
- [x] Verify shell syntax.

## Current Status

`common/init.sh` now validates `${OPS_ENV_DIR}` and required env files before package/system setup starts. Database bootstrap requires `DB_PASSWORD` from the prepared env file and will not generate a new password.
