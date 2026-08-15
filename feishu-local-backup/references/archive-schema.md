# Archive schema

## Root and identity

Resolve archives through `archive-profile.json`, an explicit archive root, and verified tenant ID. A family may contain multiple accounts or tenants; each archive keeps independent state and policies.

## Core layout

```text
README_FOR_AI.md
_meta/
  manifest.json
  completeness.json
  inventory.ndjson
  gaps.json
  checksums.sha256
  policies/
    accounts/<user_open_id>/chat_exclusions.json
    personal_knowledge_profile.json
    personal_data_decisions.ndjson
    personal_data_exclusions.ndjson
    excluded_documents.ndjson
    excluded_resources.ndjson
    excluded_files.ndjson
  reports/
  runs/<run_id>/
  state/
chats/{raw,members,attachments,quarantine}/
drive/{raw,documents,metadata,structured,files}/
  index.ndjson
wiki/{raw,documents,metadata,structured,attachments,files}/
  index.ndjson
calendar/
meetings/
minutes/
tasks/
approvals/
okr/
mail/
contacts/
attendance/
```

Do not rename an existing stable path during an incremental run. Missing domains are allowed and must be reported as `not_applicable`, `pending`, or a gap rather than fabricated.

## Knowledge and source layers

- Chat content authority: raw structured JSON envelopes.
- Document knowledge authority: validated Markdown body plus stable node/index metadata. Preserve or retire temporary raw browser captures only through an audit.
- Structured-table authority: JSON snapshots with stable IDs; native exports are optional fidelity/recovery artifacts.
- Binary authority: retained originals are supporting evidence, not automatically the preferred AI input.
- Derived reports and summaries never overwrite a higher-fidelity retained layer.

Every indexed item should expose stable ID, display title, logical hierarchy, source type, source URL when available, local path, provenance time, local status, and policy status.

Drive/Wiki content rows also expose `content_status`, `knowledge_path`, `metadata_path`, and `binary_path`. Valid content states include `pending`, `markdown`, `structured_json_and_markdown`, `exported`, `downloaded`, `metadata_only`, `inventory_only`, `review_unknown_size`, `review_size_limit`, `excluded`, and `gap`.

`InventoryOnly` is a preflight state. It may prove enumeration coverage but cannot satisfy document or file content completeness.

## Personal knowledge profile

`_meta/policies/personal_knowledge_profile.json` stores the owner's purpose and current preferences. It is private archive data and must not be copied into the Skill repository. Follow the template in `personal-knowledge-profile.template.json`.

Value decisions use:

- `keep_knowledge`: retain active text/structure and useful supporting sources.
- `extract_then_remove_binary`: validate extracted Markdown/JSON before deleting the binary.
- `review`: preserve unchanged until inspected.
- `exclude`: remove the exact local target only after explicit authorization and write a durable tombstone.

Title, folder, type, size, and keywords are signals, not sufficient deletion evidence. Record `content_inspected`, rationale, evidence paths, decision source, and timestamp.

## Exclusions and tombstones

- Chat policy: `_meta/exclusions.json` plus `_meta/deleted_attachments.json`.
- Generic personal-data policy: `_meta/policies/personal_data_exclusions.ndjson`.
- Wiki compatibility policies: `excluded_documents.ndjson`, `excluded_resources.ndjson`, and `excluded_files.ndjson`.

Any active row with `prevent_future_download: true` must be checked before a network request. Match stable IDs first and exact normalized archive-relative paths second; never match by title alone.

Chat exclusions are scoped to the authenticated user. Persist the effective stable-ID set in `_meta/policies/accounts/<user_open_id>/chat_exclusions.json`. A full exclusion or quarantine prevents message, member, reaction, retry, and attachment requests. An attachment-only exclusion still permits message JSON refresh but prevents all binary resource requests. Legacy `_meta/exclusions.json` remains a compatibility input and is migrated into the authenticated user's policy on the next synchronization.

Deletion records retain stable ID, former path, size, SHA-256, rationale, content-inspection flag, decision source, deletion time, status, and redownload policy. The source Feishu object remains untouched unless separately authorized.

## Stable identifiers

- Chat: `chat_id`; message: `message_id`; attachment: `(chat_id, resource_key)`.
- Drive/file/document: object/file token plus type.
- Wiki: `wiki_token` and underlying `obj_token`.
- Calendar: calendar ID plus event/instance ID.
- Other domains: source API resource ID or token.

## Gap semantics

Keep failed attempts separate from prior-good data. Each gap records domain, stable resource ID, reason, status, retryability, first/last attempt, and resolution time. Preserve resolved history.

## Integrity

`_meta/inventory.ndjson` describes current files only and must not reference deleted targets. `_meta/checksums.sha256` contains lowercase SHA-256, two spaces, and a forward-slash relative path for every archive file except itself.

Finalization order is mandatory: rebuild indexes/inventory/state/reports, validate JSON, write checksums as the last mutation, then verify checksum cardinality and hashes. Any later file mutation invalidates finalization.
