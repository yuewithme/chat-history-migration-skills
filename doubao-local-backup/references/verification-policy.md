# Verification policy

A candidate passes only when all checks pass.

## Conversations

- Valid non-empty JSON with supported schema and `provider: doubao`.
- Unique non-empty conversation IDs.
- Published files match raw envelopes by SHA-256.
- Valid pagination and redaction records.

## Attachments

- Manifest targets exist, are non-empty, and match size and SHA-256.
- Every reference is stored or listed as failed.
- Duplicate content maps to one path.

## Safety

- Conversation output contains only JSON; original attachments keep their formats.
- Reports contain only sanitized operational data.
- Checkpoints, indexes, reports, logs, and derived metadata contain no credentials or complete signed URLs.

Do not publish on failures, invalid JSON, bad hashes, missing files, unsafe metadata, or unaccounted attachment references.
