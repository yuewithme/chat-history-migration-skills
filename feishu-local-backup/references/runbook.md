# Feishu personal data foundation runbook

## Preflight

1. Resolve the exact archive from explicit `-ArchiveRoot`, or from `ArchiveHome + feishu + profile`. Validate root-level `archive-profile.json` before reading account data. For a new profile run `scripts/initialize_archive.ps1`; never invent a drive letter or current-directory fallback. Read `_meta/policies/personal_knowledge_profile.json`; create it from the Skill template only when missing, and keep it private to the archive.
2. If chat indexes exist, run `scripts/generate_chat_report.ps1`. Require the four rankings and automatically open the loopback report. If chat data is absent, mark the chat report `not_applicable` rather than failing Wiki work.
3. Resolve `lark-cli` from `PATH`; do not hardcode an executable location. Run `lark-cli --version` and `lark-cli auth status --json --verify` before network work.
4. Require verified user identity for personal data and keep explicit `--as user` across the workflow.
5. Read the current manifest, completeness, gaps, exclusions, tombstones, quarantine metadata, and run state.
6. Check free disk space before large attachment or native-document downloads. Enumerate metadata/text first and stage expensive binaries for review.

Use `lark-cli update` only when the user asks to update or a relevant update notice is present; it updates both the CLI and bundled Lark skills.

## Domain routing

| Domain | Skill | Raw/source policy |
|---|---|---|
| Chats, members, message resources | `lark-im` | JSON envelopes; attachments unchanged; no chat Markdown |
| Drive tree, files, native exports | `lark-drive` | Raw listing JSON plus native/Markdown exports |
| Wiki spaces/nodes | `lark-wiki` | Recursive node JSON; export underlying objects through Drive |
| Docx/Wiki bodies | `lark-doc` | Markdown when useful structured body JSON is unavailable |
| Sheets/Base/slides | `lark-sheets`, `lark-base`, `lark-slides` | Native export plus JSON metadata/index |
| Calendar | `lark-calendar` | 35-day raw JSON windows, then deduplicated JSON |
| Meetings and Minutes | `lark-vc`, `lark-minutes`, `lark-note` | Search/detail/transcript JSON and supported artifacts |
| Tasks/approvals/OKR/mail | corresponding `lark-*` skill | JSON whenever the API exposes structured output |
| Missing CLI operation | `lark-openapi-explorer` | Inspect schema before calling native OpenAPI |

Read each selected domain skill completely before executing that domain.

## Unified core-content backup

Use the unified entry point when the request includes chats plus files, Wiki, or cloud documents:

```powershell
# Default: incremental chat JSON plus full Drive/Wiki inventory and AI-ready knowledge content
.\scripts\sync_feishu_all.ps1 -ArchiveRoot <archive> -Mode Incremental -ContentMode Knowledge

# First capture with every known thread
.\scripts\sync_feishu_all.ps1 -ArchiveRoot <archive> -Mode Full -ThreadMode All -ContentMode Knowledge

# Inventory preflight only; this is not a completed content backup
.\scripts\sync_feishu_all.ps1 -ArchiveRoot <archive> -Mode Full -ContentMode InventoryOnly

# Include ordinary binaries only after reviewing the plan, tombstones, free space, and size gate
.\scripts\sync_feishu_all.ps1 -ArchiveRoot <archive> -ContentMode KnowledgeAndBinaries -MaxBinaryBytes 104857600
```

The orchestrator delegates to `sync_feishu_messages.ps1`, `sync_feishu_knowledge.ps1`, and `sync_feishu_knowledge_content.ps1`, then validates and hashes once. Use `-PlanOnly` to inspect the stages without touching an archive.

## Chat refresh

Use `scripts/sync_feishu_messages.ps1` as the primary entry point:

```powershell
# First complete capture of message JSON and all currently discoverable threads
.\scripts\sync_feishu_messages.ps1 -ArchiveRoot <archive> -Mode Full -ThreadMode All

# Routine refresh with a ten-minute overlap; refresh threads found in the incoming window
.\scripts\sync_feishu_messages.ps1 -ArchiveRoot <archive> -Mode Incremental -ThreadMode Discovered
```

The synchronizer deliberately omits `--download-resources`. Message JSON retains resource keys, while binary downloads remain a separate policy-aware stage so tombstones and storage review can be honored before each request. Do not add bulk resource download to the message command.

1. Enumerate p2p and group chats with full pagination.
2. Resolve the authenticated user's `open_id`. Load `references/exclusions.json`, legacy `<archive>/_meta/exclusions.json`, user-scoped `<archive>/_meta/policies/accounts/<open_id>/chat_exclusions.json`, and `<archive>/_meta/deleted_attachments.json`. Persist the effective chat policy under that user and apply it before making message, member, reaction, retry, or resource-download requests. Call `scripts/test_chat_attachment_tombstone.ps1` for each candidate resource key and make no download request when it exits 4.
3. For a full exclusion or quarantine policy, make no downstream chat request and keep the chat out of active indexes. For an attachment-only policy, allow message refresh without `--download-resources`, delete/ignore downloaded resources, and keep the chat in the p2p/group message index.
4. The raw `_chat_list.json` may still contain minimal enumeration metadata and must not be edited.
5. For a new non-excluded chat, fetch all messages ascending with reactions and resources unless resources are excluded.
6. For an existing non-excluded chat, read its maximum successfully stored timestamp. Fetch from ten minutes before that timestamp through the current time.
7. Save the incoming response under the current run directory.
8. Merge with `scripts/merge_chat_envelope.ps1`; deduplicate by `message_id`, prefer the incoming version of a duplicate, and sort by message position/time.
9. Refresh group members. A dissolved group failure becomes a non-retryable membership gap while existing message history remains valid.
10. If the message API fails, keep the last good raw JSON and append an error. Create an `ok:false` placeholder only when no prior-good JSON exists.

For topic completeness, `ThreadMode All` refreshes every known thread after merging and is appropriate for full/audit runs. `ThreadMode Discovered` refreshes threads surfaced by the incremental overlap. Record thread fetch failures without discarding the parent chat JSON.

For an explicit local attachment deletion, call `scripts/remove_chat_attachments.ps1 -ChatId <id> -AttachmentPath <chat-relative-path> -ConfirmDelete`. It validates containment, writes the deletion audit and durable tombstone before removal, updates attachment statistics, and rehashes the archive. The HTML report invokes the same script through `scripts/serve_chat_report.ps1`; never replace the delete endpoint with a visual-only button.

Run `scripts/apply_chat_exclusions.ps1` without `-ConfirmPurge` to preview local removals. Use `-ConfirmPurge` only when the user explicitly requests permanent removal. The script writes a body-free deletion manifest before deleting canonical chat JSON, member snapshots, and attachments.

## Drive and Wiki refresh

Enumerate all visible Drive folders and all Wiki spaces including `my_library`. Recursively traverse children with manual/verified pagination. Preserve raw page responses. Export only new/changed/missing/previously-failed objects when reliable modified metadata exists; otherwise re-export conservatively. Resolve Wiki nodes to their underlying type before choosing Markdown, structured JSON, optional native export, or a staged binary download.

Use `scripts/sync_feishu_knowledge.ps1` for deterministic enumeration and `scripts/sync_feishu_knowledge_content.ps1` for materialization. The first stage writes `drive/index.ndjson` and `wiki/index.ndjson`; the second stage updates those rows with `content_status`, `knowledge_path`, `metadata_path`, and `binary_path`.

- Doc/Docx: fetch Markdown and write a separate stable-ID metadata JSON sidecar.
- Mindnote: retain node JSON and derive a Markdown tree.
- Sheet: retain metadata and an XLSX snapshot; add structured JSON through `lark-sheets` when cell/table semantics are needed.
- Base/bitable: prefer Base APIs or a `.base` snapshot; never treat a failed browser client-variable request as an empty successful Base.
- Slides: retain metadata plus PPTX/PDF and derived text when available.
- Ordinary files: `metadata_only` is the default. `KnowledgeAndBinaries` still enforces exclusions, tombstones, byte limits, and unknown-size review before a request.

Metadata visibility does not imply content-download permission. Record permission-denied content separately from a missing node.

## Personal knowledge review

1. Read `personal-data-foundation.md` and the archive-local personal profile.
2. Use the generated review to prioritize high-storage, no-text, duplicate-looking, and previously decided items. These are review signals only.
3. Inspect actual Markdown/JSON or representative attachments. Do not exclude from title, path, extension, size, or tenant category alone.
4. Record decisions in `_meta/policies/personal_data_decisions.ndjson` with stable ID, action, rationale, evidence, `content_inspected`, and user authorization state.
5. Keep uncertain items as `review`. For `extract_then_remove_binary`, verify the replacement text/structure before deletion.
6. Preview destructive decisions with the domain-specific tombstone-aware script. Use its apply/confirmation switch only after explicit user authorization. The source Feishu workspace remains unchanged.
7. Keep tenant-specific examples and exclusions inside that archive. Promote only reusable process improvements into this Skill.

## Calendar refresh

Use bounded windows of at most 35 days. Retry an individual failed window up to three times with backoff. Save every successful window JSON. Merge and deduplicate by event/instance stable ID. Never allow one failed window to invalidate all other history.

## Finalization

1. Rebuild chat, Drive, Wiki, calendar, meetings, Minutes, and other domain indexes.
2. Rebuild `_meta/inventory.ndjson` from current files/stable resource records; confirm it contains no deleted target.
3. Reconcile current errors with `_meta/gaps.json`; preserve gap history.
4. Update `_meta/completeness.json` from current files, not stale progress counters.
5. Regenerate all JSON/HTML reports that are stored inside the archive.
6. Run `archive_maintenance.ps1 -Action ValidateJson`.
7. Mark manifest and run state complete only if required indexes exist and validation succeeds.
8. Run `archive_maintenance.ps1 -Action Rehash` as the last archive mutation.
9. Run `-Action VerifyHashes -FullHash`. If any file changes afterward, repeat steps 8–9.

## GitHub boundary

Only the Skill directory may be versioned. Before every push, run a secret scan and inspect `git status`. Never add the archive path, copied message samples, attachments, API output, `.env`, credentials, or logs.
