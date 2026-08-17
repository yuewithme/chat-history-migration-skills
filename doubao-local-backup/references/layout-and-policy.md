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
        ├── documents/              # Markdown only
        ├── reports/
        ├── final/Doubao_Backup/
        │   ├── conversations/
        │   ├── attachments/files/
        │   └── metadata/
        └── logs/
```

`archive-profile.json` layout version 3 contains the fixed relative paths. It contains no absolute path or credentials.

| Directory | Content |
|---|---|
| `tool/` | Locks and reproducible tool cache |
| `state/raw/` | Resumable conversation/attachment state and checkpoints |
| `working/` | Temporary downloads and fresh candidates |
| `documents/` | Persistent Markdown documents |
| `reports/` | Sanitized run, preflight, and failure reports |
| `final/Doubao_Backup/conversations/` | Canonical chat JSON |
| `final/Doubao_Backup/attachments/files/` | Original downloaded files |
| `final/Doubao_Backup/metadata/` | Manifests, indexes, and verification JSON |
| `logs/` | Sanitized operational logs |

Chat records are JSON. Documents are Markdown. `documents/` is persistent and is not replaced during backup publication.

Conversation names use `YYYY-MM-DD__sanitized-title__full-conversation-id.json`. Attachment names are content-addressed; identical bytes share one stored file and manifest record.
