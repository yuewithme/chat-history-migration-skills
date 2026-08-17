# Archive layout and policy

## Portable archive home

```text
<ArchiveHome>/
└── doubao/
    └── <profile>/
        ├── archive-profile.json
        ├── tool/
        ├── state/raw/
        ├── working/
        ├── reports/
        ├── final/Doubao_Backup/
        └── logs/
```

`ArchiveHome` is selected per machine; never hardcode its drive. `profile` is a stable lowercase slug for one account/archive lineage. The marker contains no absolute path or credentials.

| Directory | Content |
|---|---|
| `tool/` | Locks and reproducible tool cache |
| `state/raw/` | Resumable conversation/attachment state and checkpoints |
| `working/` | Temporary downloads and fresh candidates |
| `reports/` | Sanitized run, preflight, and failure reports |
| `final/Doubao_Backup/` | Only published, verified master copy |
| `logs/` | Sanitized operational logs |

Build every candidate under `working`. Publish only when `metadata/final-verification.json` has `passed: true`; keep the prior final until replacement succeeds and rebuild state afterward. Never infer deletion from one remote listing.

Conversation names use `YYYY-MM-DD__sanitized-title__full-conversation-id.json`. Attachment names are content-addressed; identical bytes share one stored file and manifest record.
