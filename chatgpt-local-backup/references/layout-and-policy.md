# Archive layout and policy

## Portable archive home

All migration Skills share one machine-selected home:

```text
<ArchiveHome>/
└── chatgpt/
    └── <profile>/
        ├── archive-profile.json
        ├── tool/export-chatgpt/
        ├── state/raw/
        ├── working/
        ├── final/ChatGPT_Backup/
        ├── logs/
        └── reports/
```

`ArchiveHome` may live on any local drive or mounted volume. Never store its absolute value in the Skill repository. `profile` is a stable lowercase slug for one account/archive lineage. The marker stores schema, source, profile ID, layout version, and creation time, but no absolute path or credential.

| Directory | Content |
|---|---|
| `tool/` | Third-party exporter clone and tool caches; reproducible, not authoritative archive data |
| `state/raw/` | Persistent resumable exporter state and checkpoints |
| `working/` | Disposable downloads and publication candidates |
| `final/ChatGPT_Backup/` | Only published, verified master copy |
| `logs/` | Sanitized operational logs |
| `reports/` | Verification and run summaries without chat content or credentials |

Never create peer data folders outside the selected profile root.

## Incremental state

`<root>/state/raw` is the only routine working set. New IDs download; changed conversations replace their prior state only when `update_time` differs; unchanged conversation and file IDs skip. After verified publication, rebuild from final, using hard links when supported. Preserve state after interrupted or failed export.

## Authentication and content policy

Use Kimi WebBridge only through `127.0.0.1:10086`. Keep the ChatGPT token in process memory and send authorization only to HTTPS `chatgpt.com` hosts. External signed attachment URLs receive no ChatGPT authorization.

Include active/archived conversations, Projects, project files, ordinary attachments, user/unknown images, and dictation audio. Exclude Canvas and metadata-confirmed generated images. Unknown provenance means retain.

## Published structure and publication

Use `YYYY-MM-DD__sanitized-title__full-conversation-id.json` for conversations and content-addressed names for attachments. Require conversation/project indexes, export/dedup/verification reports, final verification, and an attachment manifest.

Publish only when JSON parses, raw hashes match, every reference is stored/excluded/failed explicitly, manifest paths and hashes validate, forbidden derived formats are absent, token-shaped values are absent, and unaccepted failures are empty. Keep the previous final until replacement succeeds.
