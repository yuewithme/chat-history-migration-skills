---
name: chatgpt-local-backup
description: Safely create, refresh, resume, verify, repair, deduplicate, or inspect a portable local ChatGPT archive selected by the user. Use for ChatGPT conversations, Projects, attachments, generated/user files, voice dictation assets, manifests, incremental state, and integrity reports. Never assume a drive letter or upload private archive data.
---

# ChatGPT Local Backup

Maintain one explicitly selected ChatGPT profile archive. Never upload account data, attachments, browser credentials, or bearer tokens.

## Resolve the archive first

Use the shared archive convention `<ArchiveHome>/chatgpt/<profile>/`. Resolve the location in this order:

1. explicit `--root <profile-root>`;
2. `--archive-home <home> --profile <id>`;
3. `CHAT_HISTORY_ARCHIVE_HOME` plus `--profile <id>`.

Never invent a drive letter or fall back to the current directory. Read `archive-profile.json` and require `source: chatgpt`. A recognized legacy root without a marker may be read, but initialize/adopt it before treating it as portable.

Initialize a new profile:

```text
node scripts/init-backup.js --archive-home <home> --profile <profile-id>
```

Adopt an inspected legacy archive without moving data:

```text
node scripts/init-backup.js --root <existing-root> --profile <profile-id> --adopt-existing
```

Read [references/layout-and-policy.md](references/layout-and-policy.md) before changing layout, inclusion, authentication, or cleanup behavior.

## Workflow

1. Resolve and report the exact profile root. Stop on a source/profile mismatch.
2. Check that Edge is logged into the intended `chatgpt.com` account and Kimi WebBridge is connected at `127.0.0.1:10086`. Do not read Edge's credential store.
3. Clone or fast-forward `brianjlacy/export-chatgpt` under `<root>/tool/export-chatgpt`. Record the commit; stop on unrelated changes.
4. Review upstream hosts and install-script changes. Run `npm install --ignore-scripts`, then `node scripts/patch-exporter.js --tool <root>/tool/export-chatgpt` and upstream tests.
5. If `<root>/state/raw` is absent, or immediately after successful publication, run `node scripts/rebuild-incremental-state.js --root <root>`. Never rebuild state after an incomplete run.
6. Run `node scripts/run-raw-export.js --root <root> --raw <root>/state/raw`. New IDs download; existing conversations refresh only when `update_time` changed.
7. Organize into a fresh `<root>/working/candidate-<run-id>` with `organize-backup.js`, then verify it with `verify-backup.js`.
8. Publish only on `passed: true` using `node scripts/publish-backup.js --root <root> --candidate <candidate>`, then rebuild state and verify final again.

## Required behavior

- Use JSON-only output with active, archived, Project, attachment, image, and dictation coverage; exclude Canvas.
- Preserve raw Conversation JSON byte-for-byte.
- Keep user/unknown images. Exclude only metadata-confirmed generated images and record the reason.
- Deduplicate retained files by SHA-256 and generate manifests/reports with `null` for unknown metadata.
- Never generate chat Markdown, HTML, PDF, TXT, JSONL, or ZIP by default.
- Never print, persist, commit, or upload a bearer/session token.
- Keep the last verified final and resumable state when any phase fails.

## Stop conditions

Stop and report evidence when authentication/account selection is ambiguous, an unknown host receives credentials, raw JSON changes after copying, a file reference is unexplained, a manifest path/hash fails, or verification detects a token-like value or forbidden derived format.

## Git boundary

Version only Skill instructions, UI metadata, scripts, references, tests, README, license, and CI configuration. Keep workspace rules and archive memory outside the Skill repository. Never commit an archive root, exporter clone, `node_modules`, logs, tokens, or real fixtures.
