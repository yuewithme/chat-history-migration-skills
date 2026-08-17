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
        ├── documents/
        │   ├── markdown/
        │   ├── json/
        │   └── indexes/
        ├── reports/
        ├── final/Doubao_Backup/
        │   ├── conversations/
        │   ├── attachments/files/
        │   └── metadata/
        └── logs/
```

`archive-profile.json` layout version 2 contains the fixed relative paths. It contains no absolute path or credentials.

| Directory | Content |
|---|---|
| `tool/` | Locks and reproducible tool cache |
| `state/raw/` | Resumable conversation/attachment state and checkpoints |
| `working/` | Temporary downloads and fresh candidates |
| `documents/markdown/` | Persistent Markdown documents |
| `documents/json/` | Structured document JSON |
| `documents/indexes/` | Document catalogs and links |
| `reports/` | Sanitized run, preflight, and failure reports |
| `final/Doubao_Backup/conversations/` | Canonical chat JSON |
| `final/Doubao_Backup/attachments/files/` | Original downloaded files |
| `final/Doubao_Backup/metadata/` | Manifests, indexes, and verification JSON |
| `logs/` | Sanitized operational logs |

`documents/` is persistent and is not replaced during backup publication. Build candidates under `working`; publish only after verification passes.

Conversation names use `YYYY-MM-DD__sanitized-title__full-conversation-id.json`. Attachment names are content-addressed; identical bytes share one stored file and manifest record.
