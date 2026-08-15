# Full backup coverage matrix

Use this reference for a full Feishu/Lark capture or when deciding whether an archive is actually complete. “Full” means every accessible stable object is enumerated and receives an explicit status. It does not mean blindly downloading every binary.

## Core content domains

| Domain | Discovery | Authority stored locally | Binary policy | Required completion evidence |
|---|---|---|---|---|
| Chats and threads | `lark-im` through `sync_feishu_messages.ps1` | JSON envelopes | Resources are a separate tombstone-aware stage | Every visible non-excluded chat has a result; pagination and thread gaps are explicit |
| Drive folders and files | recursive `drive files list` | Raw page JSON plus `drive/index.ndjson` | Download ordinary files only after policy/size review | Every folder queue and page cursor is exhausted or recorded as a gap |
| Wiki spaces and nodes | `wiki +space-list`, `my_library`, recursive `wiki +node-list` | Raw page JSON plus `wiki/index.ndjson` | Route by underlying `obj_type` | Every space, parent queue and child page is exhausted or recorded as a gap |
| Doc/Docx | `docs +fetch --doc-format markdown` | Markdown body plus stable-ID JSON metadata | Embedded media are indexed; download separately | Markdown exists and metadata retains source/revision/reference information |
| Sheets | Wiki/Drive discovery, then `lark-sheets` or Drive export | Structured JSON when available; XLSX/CSV as fidelity artifacts | No image/video fan-out by default | Tables/sheets are enumerated; unsupported structure becomes a gap |
| Base/bitable | Wiki/Drive discovery, then `lark-base` or `.base` export | Structured JSON and/or `.base` snapshot plus metadata | Attachments remain policy-controlled | Tables, fields, views and records are covered or gaps identify the missing layer |
| Slides | Wiki/Drive discovery, then `lark-slides` or PPTX export | JSON metadata plus PPTX/PDF; derived text when available | Media remain policy-controlled | Native export or a typed gap exists for every presentation |
| Mindnote | `mindnotes nodes list` | Node JSON plus derived Markdown tree | Images are indexed; download separately | All returned nodes are retained; unresolved images are explicit |
| Ordinary files | Drive/Wiki discovery | Metadata/index JSON and optional unchanged binary | Default is review; enforce tombstones and byte limits before request | Every file has `downloaded`, `metadata_only`, `excluded`, `review`, or gap status |

## Additional structured domains

The top-level Skill also covers calendar, meetings, Minutes, tasks, approvals, OKR, mail, contacts, and attendance. Route each through the matching `lark-*` module named in `runbook.md`, retain structured JSON, paginate fully, and merge by stable source ID. Do not let success in the core content domains imply these domains were attempted.

For each domain write one of:

- `complete`: the confirmed scope and pagination were exhausted;
- `complete_with_gaps`: usable data is present and exact failures remain;
- `not_applicable`: the authenticated account exposes no such product or scope after a valid enumeration;
- `pending`: the domain has not been attempted;
- `blocked`: a durable permission, product, or API limitation prevents collection.

## Lessons from real runs

These are reusable process findings, not tenant-specific value judgments:

1. A Wiki root response is not a full tree. Follow every `has_child` node and every child page token. A `child_paging` signal without verified continuation is a gap, never completion.
2. Wiki enumeration must include the user’s `my_library`; the normal space list does not return it.
3. Wiki tokens are containers. Resolve `obj_token` and `obj_type` before fetching, exporting, or downloading.
4. Prefer `lark-cli`/OpenAPI over browser `clientvars` or private browser requests. Browser extraction may be used only as an audited fallback and must record its incomplete or fragile fields.
5. Docx conversion is complete only after Markdown and metadata both validate. Do not keep raw browser bodies as the document authority.
6. Base browser discovery can fail even when the node is visible. Prefer Base APIs or `.base` export and record a typed gap instead of emitting an empty table.
7. Sheets and Base are structured data, not prose documents. Markdown summaries may be derived, but structured JSON/native snapshots remain authoritative.
8. Enumerate metadata and text before binaries. Apply archive-local decisions, exclusions, deletion tombstones, size gates, and free-space checks before every download request.
9. A large attachment count is not evidence of knowledge value. Keep the stable reference even when the binary is excluded or reduced to extracted text.
10. Persist per-domain progress and gaps so an interrupted run resumes instead of restarting or silently skipping previously failed objects.

## Full-run acceptance gate

A full run is publishable only when:

1. the verified `user` identity and tenant/account key are recorded;
2. every requested domain has an explicit status;
3. active exclusions and tombstones were loaded before fan-out;
4. chat JSON, document Markdown, structured snapshots, ordinary-file metadata and stable hierarchy indexes validate;
5. `_meta/inventory.ndjson`, `_meta/completeness.json`, `_meta/gaps.json`, the manifest and run state agree;
6. reports are regenerated before checksums;
7. SHA-256 is written as the final mutation and full verification passes.

Never label an archive `complete` merely because thousands of files exist. Completion is domain coverage plus verified integrity.
