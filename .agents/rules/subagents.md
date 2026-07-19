# Subagent Usage

Use subagents when they materially improve progress or quality.

Good cases:

- large or separable analysis,
- remote-server investigation plus local script changes,
- security/ops review,
- deployment failure triage with broad logs,
- independent review/verification.

Avoid subagents for:

- narrow edits,
- docs/spec/rules-only changes,
- simple explanations,
- targeted bug fixes the primary agent can inspect directly.

The primary agent remains responsible for integrating results, following repository rules, and reporting which subagents were used when they are used.

Subagent definition files live under repository-root `.agents/subagents/`.

Check `.agents/subagents/index.md` before scanning subagent definition files.
