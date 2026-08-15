---
name: doubao-local-backup
description: Back up, resume, verify, repair, or inspect complete Doubao chat history and attachments under D:\Doubao_Backup through the user's logged-in browser session. Use for 豆包/Doubao migration, incremental backup, raw JSON capture, attachment recovery, checkpoint resume, integrity checks, and local archive maintenance.
---

# Doubao Local Backup

Use the existing logged-in Doubao browser session. Keep all requests read-only.

## References

- Read [capture-contract.md](references/capture-contract.md) for browser capture, pagination, or attachment changes.
- Read [layout-and-policy.md](references/layout-and-policy.md) for storage or publication changes.
- Read [verification-policy.md](references/verification-policy.md) for verification or repair.
- Read [reporting.md](references/reporting.md) for result handling.

## Main entry

Initialize once if needed:

```text
node scripts/init-backup.js
```

Run the complete chain:

```text
node scripts/run-auto-backup.js --root D:\Doubao_Backup
```

Use `--complete-listing` only for a full remote-list audit. The default scan checks recent items; changed conversations are still fetched completely.

## Rules

1. Confirm the intended account is logged in.
2. Capture the current official request before replaying pagination.
3. Save each conversation atomically, then download its attachments.
4. Resume from `D:\Doubao_Backup\state\raw`; do not discard checkpoints after failure.
5. Build a new candidate under `working`.
6. Publish only after candidate verification passes.
7. Rebuild state and verify final after publication.

- Never access the browser credential store.
- Never persist authentication material or complete signed URLs.
- Never delete local history based on one remote listing.
- Never upload account data or real fixtures.
- Keep the last verified final when any phase fails.

Retry only failed attachments with:

```text
node scripts/repair-existing-attachments.js --root D:\Doubao_Backup
```
