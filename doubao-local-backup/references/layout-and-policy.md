# Layout and policy

```text
D:\Doubao_Backup\
├─ state\raw\
├─ working\
├─ reports\
├─ final\Doubao_Backup\
└─ logs\
```

- `state\raw` is the resumable working set.
- Build each candidate in a new `working` directory.
- Publish only when `metadata\final-verification.json` has `passed: true`.
- Keep the prior final until replacement succeeds; restore it on failure.
- Rebuild state from final after publication.
- Never infer deletion from one remote listing.

## Names

- Conversation: `YYYY-MM-DD__sanitized-title__full-conversation-id.json`
- Attachment: `<sha256-first-16>__<first-attachment-id><original-extension>`

Identical attachment content shares one stored file and manifest record.
