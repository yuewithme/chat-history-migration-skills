# Layout and policy

## Local tree

```text
D:\ChatGPT_Backup\
├── tool\export-chatgpt\            # cloned third-party exporter
├── state\raw\                      # persistent resumable incremental state
├── working\                        # transient candidates only
├── final\ChatGPT_Backup\           # only published master copy
│   ├── conversations\regular\
│   ├── conversations\projects\
│   ├── attachments\files\
│   ├── attachments\manifest.json
│   ├── metadata\
│   └── README.txt
├── scripts\                         # optional local copies/wrappers
└── logs\
```

Do not create peer folders in `D:\`; everything belongs under the single root.

## Incremental-state policy

`D:\ChatGPT_Backup\state\raw` is the only exporter working set used for routine weekly runs. Its indexes and `.export-progress.json` record stored metadata, downloaded conversation IDs, and file IDs. New IDs are downloaded; existing conversations are selectively replaced when their current `update_time` differs from the stored index. Unchanged conversation and file IDs are skipped.

After a verified publication, rebuild the state from the published backup. The rebuild uses NTFS hard links for Conversation JSON and retained files when source and destination share a volume. Multiple paths then reference the same physical bytes. If hard links are unavailable, the script reports each fallback copy.

Do not rebuild after an interrupted or failed export. Preserve the state and resume it. The published backup remains unchanged until a new candidate passes verification.

## Authentication boundary

Use Kimi WebBridge only through `http://127.0.0.1:10086`. Borrow or open a `chatgpt.com` Edge tab, call `/api/auth/session` in that page, and pass `accessToken` directly in memory to the exporter child process. Never serialize the response, put the token in a command argument, echo it, or place it in a request file.

The exporter may attach authorization only to HTTPS `chatgpt.com` or its subdomains. External signed attachment URLs receive no ChatGPT authorization header. Reject non-HTTPS download URLs.

Kimi WebBridge may emit its own daemon-alive telemetry; the user explicitly accepted that on 2026-08-13. This does not authorize sending ChatGPT tokens, conversations, or attachments to Kimi or any other third party.

## Inclusion policy

- Include active and archived conversations, Project conversations, Project-level files, ordinary attachments, user/unknown images, and voice dictation (`m4a`/`webm`).
- Exclude Canvas.
- Exclude an image only when `metadata.dalle` or `metadata.generation` is present. Record its file ID, size, and exclusion reason.
- Unknown provenance means retain.

## Published structure

Conversation filename: `YYYY-MM-DD__sanitized-title__full-conversation-id.json`.

Attachment filename: `<sha256-first-16>__<file-id>.<ext>`. Multiple file IDs with identical content map to one manifest entry.

Required reports:

- `metadata/conversation-index.json`
- `metadata/project-index.json`
- `metadata/export-report.json`
- `metadata/dedup-report.json`
- `metadata/verification-report.json`
- `metadata/final-verification.json`

## Publication rule

A candidate is publishable only when:

- every Conversation JSON parses, is non-empty, has a unique ID, and hashes identically to raw;
- every manifest path exists and hashes to the declared SHA-256;
- every raw file reference is stored, explicitly excluded, or failed with an error;
- no Markdown, HTML, JSONL, or ZIP exists;
- no JWT-shaped value is found;
- failed conversation/file arrays are empty unless the user explicitly accepts an incomplete backup.

Keep the previous final backup until the candidate passes. Never delete the only verified copy.
