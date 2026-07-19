# Test Status

## Checks Run

- `bash -n scripts/deploy/dinpanel/common/init.sh`
- `bash -n scripts/deploy/dinpanel/test/init.sh`
- `bash -n scripts/deploy/dinpanel/prod/init.sh`

## Checks Not Run

- Init was not executed.
- Database mutation was not executed.
- ShellCheck was not run because it is not installed in this environment.

## Hardening

Live verification requires running init against a prepared test ops env directory.
