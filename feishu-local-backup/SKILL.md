---
name: feishu-local-backup
description: Build, refresh, curate, and verify a private Feishu/Lark data foundation in a user-selected local archive. Use for Feishu export, incremental backup, multi-tenant discovery, chats, Wiki, documents, Drive, Sheets, Base, attachments, personal knowledge-value review, durable exclusions, AI-readable indexes, JSON validation, and SHA-256 integrity. Keep source-specific judgments in each archive's personal profile; never generalize one tenant's relevance rules or upload private archive data to GitHub.
---

# Feishu Personal Data Foundation

Maintain private Feishu archives as durable, AI-readable personal data rather than indiscriminate file dumps.

## Core contract

- Interpret a requested “full Feishu backup” as all-domain coverage, not message-only export. Enumerate chats, Drive, Wiki including `my_library`, cloud documents, Sheets, Base, Slides, Mindnote, ordinary files, and any requested structured collaboration domains. Give every requested domain an explicit completion status.
- Treat every accessible source item as data. Separate collection, knowledge value, and storage value; do not equate low current value with permission to delete.
- Keep general workflow in this Skill. Keep the user's evolving goals and source-specific decisions in `<archive>/_meta/policies/personal_knowledge_profile.json` and decision/tombstone files.
- Never turn one tenant's examples, directory names, or rejected products into universal value rules.
- Inspect content, a representative excerpt, or a representative attachment before a high-confidence value judgment. Title and path are discovery signals only.
- Use four decisions: `keep_knowledge`, `extract_then_remove_binary`, `review`, and `exclude`. Default to `review` when uncertain.
- Require explicit user authorization plus an exact reviewed decision before destructive local deletion. Never delete source-system data unless separately requested.

## Format contract

- Chats: authoritative JSON; generate Markdown only as a temporary/on-demand view.
- Cloud documents: Markdown knowledge text plus stable-ID JSON metadata. Retire raw body captures only after full conversion validation and an audit record.
- Sheets and Base: structured JSON; retain a native export only when it adds recoverability or fidelity.
- PDF, PPT, DOCX, images, audio, and video: supporting source artifacts. Extract useful text/structure first; retain or remove the binary according to its personal knowledge value and storage cost.
- Attachments: keep unchanged when retained, store under the owning stable ID, and enforce durable tombstones before any future download.

## Resolve the target

- Use the shared path `<ArchiveHome>/feishu/<profile>/`. Prefer explicit `-ArchiveRoot`; otherwise use `-ArchiveHome` / `CHAT_HISTORY_ARCHIVE_HOME` plus `-ProfileId`. Never infer a drive letter or use the current directory.
- Initialize new profiles with `scripts/initialize_archive.ps1 -ArchiveHome <home> -ProfileId <id>`. Adopt a reviewed legacy archive with `-ArchiveRoot <existing> -ProfileId <id> -AdoptExisting`; this adds a portable marker without moving data.
- Read root-level `archive-profile.json` and require schema `chat-history-archive-profile-v1`, `source: feishu`, and the intended stable profile ID. Never select by display title alone.
- Use explicit `--as user` for personal resources. Do not switch to bot identity or request new scopes silently.
- Treat each archive root as durable state. Do not create a new dated root unless the user requests a separate snapshot.

## Required workflow

1. Read `references/runbook.md` and the selected archive's profile, manifest, completeness, gaps, exclusions, tombstones, and last run state. For a full backup, also read `references/full-backup-matrix.md` and do not stop after chats succeed.
2. Before message synchronization, generate and automatically open the four-table chat HTML when an existing chat index is present. A first-time empty archive is `not_applicable` until enumeration finishes. Use `-NoOpen` only for unattended tests.
3. Enumerate metadata and text before bulk binary downloads. Check free disk space and present large/unsupported resources for review.
4. Route each Feishu domain through the smallest relevant `lark-*` skill. Use read-only source operations unless the user separately requests a Feishu write.
5. Preserve stable IDs, hierarchy, timestamps, provenance, and permission gaps. Never replace prior-good data with an error or empty result.
6. Evaluate personal knowledge value with `references/personal-data-foundation.md`. Apply explicit stable-ID policies before heuristic signals; keep ambiguous content.
7. Preview every destructive decision. Apply it only through a tombstone-aware script that hashes exact active targets, rejects path escapes/reparse points, updates indexes/inventory, and prevents redownload.
8. Finalize in one order: rebuild domain indexes → inventory → completeness/gaps/manifest/run state → regenerate reports → validate JSON → Rehash as the last mutation → VerifyHashes. If anything mutates afterward, repeat Rehash and verification.

## Full backup execution

- Use `scripts/sync_feishu_all.ps1` as the single core-content entry point. Its default sequence is chat JSON, recursive Drive/Wiki inventory, document/structured content materialization, then one final validation and checksum pass.
- Use `ContentMode Knowledge` by default: enumerate all objects, save text and structure, and leave ordinary binaries as metadata/review unless policy requires them. Use `KnowledgeAndBinaries` only after reviewing storage and exclusion/tombstone policy.
- Treat `InventoryOnly` as a preflight, never as a completed content backup.
- Route calendar, meetings, Minutes, tasks, approvals, OKR, mail, contacts, attendance, and other selected structured domains through the corresponding `lark-*` modules in `references/runbook.md`. Store JSON and merge by stable source ID. Core-content success does not imply those domains were attempted.
- Prefer `lark-cli`/OpenAPI. Use a signed-in browser only as an audited fallback when the CLI cannot access an otherwise user-visible object; record the fallback method and its coverage gaps without persisting cookies or private request credentials.

## Safety boundaries

- Never persist credentials, cookies, tokens, device codes, or authorization URLs.
- Never infer a successful download from metadata alone.
- Never treat permission failure, timeout, expired content, dissolved group, or unsupported export as an empty successful resource.
- Read `references/exclusions.json` before chat work and all archive-local `excluded_*.ndjson`/tombstone policies before document, file, or resource work.
- Resolve the authenticated user's `open_id` and load `_meta/policies/accounts/<open_id>/chat_exclusions.json` before enumeration fan-out. Persist confirmed exclusions there so future full and incremental runs skip the same chats by default.
- Bind report mutation services only to `127.0.0.1`, require a per-launch token, and resolve deletion targets from the current active inventory.
- Never commit the archive, message samples, attachments, API output, audit bodies, or credentials. GitHub may contain only Skill instructions, schemas, scripts, and synthetic fixtures.

## Operations

- Initialize or adopt a portable archive profile: `scripts/initialize_archive.ps1`.
- Unified core-content backup: `scripts/sync_feishu_all.ps1`.
- Full/incremental message synchronization: `scripts/sync_feishu_messages.ps1`. It writes authoritative JSON, expands threads according to mode, applies exclusions before downstream calls, merges with an overlap window, preserves prior-good data on failure, and does not bulk-download attachments.
- Recursive Drive/Wiki inventory: `scripts/sync_feishu_knowledge.ps1`. It includes `my_library`, follows child/page continuations, retains raw enumeration envelopes, and writes stable NDJSON indexes.
- Knowledge materialization: `scripts/sync_feishu_knowledge_content.ps1`. It creates document Markdown plus JSON metadata, Mindnote JSON plus Markdown, Sheet XLSX, Base `.base`, Slides PPTX, and optional policy/size-gated ordinary files.
- Add or replace a future chat exclusion for one Feishu user: `scripts/set_account_chat_exclusion.ps1`. It updates policy only; use the separate apply scripts when existing local data must be purged or quarantined.
- Status/integrity: `scripts/archive_maintenance.ps1`.
- Chat report and deletion: `scripts/generate_chat_report.ps1`, `scripts/serve_chat_report.ps1`, and `scripts/remove_chat_attachments.ps1`.
- Chat merge and exclusions: use the existing `merge_*`, `apply_*`, and tombstone scripts in `scripts/`.

Read `references/archive-schema.md` before changing layouts, indexes, or policy semantics. Report the archive path, requested and completed domains, operation mode, changed counts/bytes, decision counts, validation results, checksum result, and unresolved gap categories.
