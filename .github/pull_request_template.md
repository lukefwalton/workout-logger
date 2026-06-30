## What & why

<!--
Heads up: this repo is source-available, not open source. It doesn't accept
unsolicited feature/refactor/dependency PRs — please open an issue first so we
can agree on the change (see CONTRIBUTING.md). For an agreed-upon fix, describe
what changed and why, and link the issue (e.g. Closes #12).
-->

## Checklist

- [ ] Discussed first in an issue (or it's a small, obvious bug/docs fix)
- [ ] CI passes (iOS tests + the App Group identifier guardrail)
- [ ] Tests added or updated for new logic, where it applies
- [ ] Schema change? Includes a migration and tests
- [ ] Respects the doctrine: local-first, one write path, model proposes / app writes
- [ ] Docs updated if behavior or setup changed
