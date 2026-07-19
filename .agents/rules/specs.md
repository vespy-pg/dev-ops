# Feature Specs

## Canonical Location

- Store feature and operational workflow specs in repository-root `.agents/spec/`.
- Check `.agents/spec/index.md` before scanning spec directories.

## Required Workflow

- Before non-trivial planning, analysis, implementation, review, or tests, read the relevant spec entry point.
- For directory specs, read `index.md` first, then only linked files needed for the task.
- If no relevant spec exists for substantial ops behavior, create it before implementation continues.
- If no relevant spec exists, gather full context first:
  - scripts and call paths,
  - remote/server behavior if relevant,
  - environment variables and secrets boundaries,
  - verification and rollback implications.

## Directory Spec Format

Use:

- `index.md` - compact menu, metadata, problem/objective, checklist, status.
- `contract.md` - durable current script/infra/environment behavior.
- `test-status.md` - verification state, gaps, hardening statement.
- `decisions.md` - durable architecture/ops decisions.
- `implementation-log.md` - historical notes only.

Do not put bulky history in `index.md`.

## Update Rule

After each implementation batch, update compact spec files:

- `index.md`: current status/checklist.
- `contract.md`: current behavior and operational contract.
- `test-status.md`: tests/checks run, tests/checks not run, hardening gaps.
- `decisions.md`: durable technical or operational decisions.
- `.agents/spec/index.md`: update when title/status/path/slug changes.

Do not update only `implementation-log.md` for implementation work.

## Plans

- Create formal plan documents only when explicitly requested.
- Plans go under `.agents/var/docs/` and must include a checklist.
- When executing a plan, use the checklist from the plan, not a new checklist.
