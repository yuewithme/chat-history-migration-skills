# Capture contract

## Browser

- Use an already logged-in `https://www.doubao.com` page through `127.0.0.1:10086`.
- Capture the current official request and first response before replaying pagination.
- Prefer page-context requests. If a verified request hangs, use only cookies for the exact captured Doubao URL through CDP and keep them in memory.
- Never read the credential store or persist cookies, headers, tokens, device credentials, request bodies, or complete signed URLs.

## Envelope

Store one JSON file per conversation with:

- `archive_schema_version`, `provider`, `conversation_id`, `collected_at`
- response pages with `kind`, `cursor`, `next_cursor`, and `response`
- `redactions` containing JSON Pointer and reason
- derived title, timestamps, message IDs, and attachment references

Preserve provider fields and values. Replace only authentication material and complete ephemeral signed URLs with `null`, recording each redaction.

## Verified endpoints

| Purpose | Contract |
|---|---|
| List | `POST /im/chain/recent_conv`, `cmd=3200`, `direction=3` latest, `direction=1` older, size 20 |
| Detail | `POST /im/chain/single`, `cmd=3100`, `direction=1`, size 20, initial anchor `999999` |
| Attachment | `POST /alice/message/get_file_url`, stable `uris`, `type=file|image` |

IM requests use `Content-Type: application/json; encoding=utf-8`. Convert provider cursors with `Number()`.

Stop pagination on the provider completion flag, missing next cursor, two pages without new stable message IDs, or the page guard.

## Attachments

Resolve stable `file.uri` or `image.uri`; do not use preview `file.url` as the original. Use `main_url`, then `back_url`, in memory only.

Download to `.partial`, require non-zero size, calculate SHA-256, then rename atomically. Verify provider MD5 for files when present; keep image MD5 as reference metadata.
