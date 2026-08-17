---
name: doubao-local-backup
description: Back up, resume, verify, repair, or inspect complete Doubao chat history and attachments in a user-selected portable local archive. Use for 豆包/Doubao migration, incremental capture, raw JSON, attachment recovery, checkpoints, integrity checks, and archive maintenance. Never assume a drive letter or upload private archive data.
---

# Doubao Local Backup

Use the intended logged-in Doubao browser session and keep source requests read-only.

## Resolve the archive first

Use `<ArchiveHome>/doubao/<profile>/`. Resolve the location from explicit `--root`, or from `--archive-home` / `CHAT_HISTORY_ARCHIVE_HOME` plus `--profile`. Never default to a drive letter or current directory.

Initialize a profile:

```text
node scripts/init-backup.js --archive-home <home> --profile <profile-id>
```

Adopt an inspected legacy archive without moving it:

```text
node scripts/init-backup.js --root <existing-root> --profile <profile-id> --adopt-existing
```

Require `archive-profile.json` with `source: doubao`. Layout version 2 fixes chat JSON, original files, Markdown documents, document JSON, indexes, state, reports, logs, and tool paths.

## References

- Read [capture-contract.md](references/capture-contract.md) for browser capture, pagination, or attachment changes.
- Read [layout-and-policy.md](references/layout-and-policy.md) for storage or publication changes.
- Read [verification-policy.md](references/verification-policy.md) for verification or repair.
- Read [reporting.md](references/reporting.md) for result handling.

## Main workflow

Run the complete chain with one resolved profile root:

```text
node scripts/run-auto-backup.js --root <profile-root>
```

Use `--complete-listing` only for a full remote-list audit. The default scans recent items; changed conversations are still fetched completely.

1. Confirm the intended account is logged in.
2. Capture the current official request before replaying pagination.
3. Save chat JSON atomically, then download original attachments under `<root>/working/downloads`.
4. Resume from `<root>/state/raw`; never discard checkpoints after failure.
5. Build a fresh candidate under `<root>/working`.
6. Publish only after candidate verification passes.
7. Rebuild state and verify final after publication.

Retry failed attachments with `node scripts/repair-existing-attachments.js --root <profile-root>`.

Store persistent Markdown in `<root>/documents/markdown`, document JSON in `<root>/documents/json`, and document indexes in `<root>/documents/indexes`. Do not write these into `working` or `final`.

## Safety and Git boundary

- Never access the browser credential store or persist authentication material and complete signed URLs.
- Never delete local history based on one remote listing.
- Never upload account data or use real archive content as a fixture.
- Keep the last verified final when any phase fails.
- Version only Skill instructions, UI metadata, scripts, references, synthetic tests, README, license, and CI configuration.
