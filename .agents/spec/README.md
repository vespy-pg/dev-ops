# Specifications Directory

This directory stores feature and operational workflow specs for `vespy-dev-ops`.

## Structure

- `index.md` - registry/menu of active feature and draft specs
- `features/` - implementation-tracked specs
- `drafts/` - discovery/proposal specs not yet implementation-committed
- `templates/` - reusable spec templates/examples
- `reference/` - project-wide baseline and inventory docs

## Naming Rules

- Preferred specs use a directory:
  - `features/<feature-slug>/index.md`
  - `features/<feature-slug>/contract.md`
  - `features/<feature-slug>/test-status.md`
  - `features/<feature-slug>/decisions.md`
  - `features/<feature-slug>/implementation-log.md`
- Drafts use the same structure under `drafts/<feature-slug>/`.
- Small single-file specs are allowed when appropriate and must use: `YYYYMMDD-<topic>-spec.md`.
- Template/reference files are exempt from date prefixes.

## Typical Workflow

1. Check `index.md` for an existing matching feature/draft spec.
2. Copy `templates/directory-spec-template/` or the closest specialized template.
3. Save new specs in `features/<feature-slug>/` or `drafts/<feature-slug>/`.
4. Add the new spec to the registry `index.md`.
5. Fill discovery and checklist before implementation.
6. During normal work, read the feature's `index.md`, then only linked files needed for the task.
7. Update compact spec files after each implementation batch.
