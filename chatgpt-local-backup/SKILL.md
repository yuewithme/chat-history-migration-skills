---
name: chatgpt-local-backup
description: Safely create or update the user's complete local ChatGPT history backup under D:\ChatGPT_Backup using brianjlacy/export-chatgpt and the existing Edge login via Kimi WebBridge. Use when the user asks to back up, refresh, continue, verify, repair, deduplicate, or inspect the local ChatGPT backup, including conversations, Projects, uploaded/generated files, voice dictation assets, manifests, and integrity reports.
---

# ChatGPT Local Backup

Maintain one local backup tree rooted at `D:\ChatGPT_Backup`. Never upload account data, attachments, browser credentials, or bearer tokens.

## Fixed paths

- Root: `D:\ChatGPT_Backup`
- Upstream tool: `D:\ChatGPT_Backup\tool\export-chatgpt`
- Temporary/resumable exports: `D:\ChatGPT_Backup\working`
- Persistent incremental state: `D:\ChatGPT_Backup\state\raw`
- Published backup: `D:\ChatGPT_Backup\final\ChatGPT_Backup`
- Local operational scripts: `D:\ChatGPT_Backup\scripts`
- Logs: `D:\ChatGPT_Backup\logs`

Read [references/layout-and-policy.md](references/layout-and-policy.md) before changing layout, inclusion rules, authentication handling, or cleanup behavior.

## Workflow

1. Check that Edge is logged into the intended `chatgpt.com` account and Kimi WebBridge is connected at `127.0.0.1:10086`. Do not read Edge's credential store.
2. Clone or fast-forward `https://github.com/brianjlacy/export-chatgpt.git` at the upstream-tool path. Record the exact commit. Stop on unrelated local changes; preserve the security patch.
3. Review upstream network hosts and dependency/install-script changes before execution. Run `npm install --ignore-scripts` and targeted tests when the commit changes.
4. Run `node scripts/patch-exporter.js --tool <tool-path>`. It must enforce credential host isolation and add voice-dictation asset discovery. Run upstream unit tests afterward.
5. If `state\raw` does not exist, or immediately after a successful publication, run `node scripts/rebuild-incremental-state.js`. This creates exporter-compatible state from the verified final backup. Conversation JSON and retained assets use NTFS hard links when possible, so the state does not consume a second physical copy.
6. Run `node scripts/run-raw-export.js --tool <tool-path> --raw D:\ChatGPT_Backup\state\raw`. This obtains a short-lived token from the current Edge session through the local WebBridge, keeps it in process memory, and invokes the exporter with JSON-only output, Projects, archived chats, attachments, images, and no Canvas. New IDs are downloaded. Existing conversation IDs are downloaded again only when the current list `update_time` differs from the stored index; unchanged IDs and unchanged file IDs are skipped.
7. If interrupted or the token expires, reuse `state\raw` exactly as-is. Never rebuild or delete incremental state after an incomplete run because it contains resumable progress.
8. Run `node scripts/organize-backup.js --raw D:\ChatGPT_Backup\state\raw --out <candidate-path> --tool <tool-path>` into a new candidate directory under `final`.
9. Run `node scripts/verify-backup.js --raw D:\ChatGPT_Backup\state\raw --final <candidate-path>`. Publish only when it reports `passed: true`.
10. Run `node scripts/publish-backup.js --candidate <candidate-path>` to replace the published backup with rollback protection, then run `node scripts/rebuild-incremental-state.js` to compact/reset the weekly state from the new verified final.

## Required export behavior

- Use `--format json --no-user-dir --no-canvas --include-archived --non-interactive --no-donate`.
- Do not use `--no-files`, `--no-attachments`, `--no-projects`, or `--no-images`.
- Keep user/unknown images. Exclude only images whose raw metadata explicitly identifies DALL-E/image generation.
- Preserve raw Conversation JSON byte-for-byte; only copy, rename, and relocate it.
- Discover both content `asset_pointer` values and metadata `dictation_asset_pointer` values.
- Deduplicate retained files by SHA-256, not filename or file ID.
- Generate `attachments/manifest.json` and metadata reports. Use `null` when metadata is unknown.
- Never generate Markdown, HTML, PDF, TXT copies of chats, JSONL, or ZIP by default.
- Never print, persist, commit, or upload a bearer/session token.
- Selective refresh compares `update_time` for regular and Project conversations. Replace changed Conversation JSON only inside resumable state, then publish it only after complete verification. This also adds newly referenced files and removes no-longer-referenced files from the next published manifest. Use a separately approved full `--update` run only when upstream timestamps are known to be unreliable.

## Weekly automation

- Bind the task to the repository containing this Skill and explicitly invoke `$chatgpt-local-backup` in the task prompt.
- Use the local project environment, not a worktree: Edge/WebBridge and `D:\ChatGPT_Backup` are machine-local dependencies.
- Before starting a new cycle, inspect `state\raw` and the latest final verification. Resume incomplete state instead of rebuilding it.
- A successful cycle must export, organize, verify, publish, rebuild incremental state, and report new/skipped/error counts. Never publish when verification fails.

## Stop conditions

Stop and report evidence instead of continuing if:

- upstream sends credentials or account data to an unknown host;
- WebBridge/Edge cannot safely provide the current session token;
- the account/workspace is ambiguous;
- raw JSON cannot parse or differs after copying;
- any referenced file is neither stored, explicitly excluded as generated, nor recorded failed;
- a manifest path/hash is invalid;
- final verification detects a JWT-like token or forbidden derived format.

## Git hygiene

The public Skill package may contain `SKILL.md`, `agents/`, `scripts`, and `references`. Keep workspace rules, archive memory, account data, exports, attachments, logs, tokens, `node_modules`, and the cloned upstream repository outside the package.
