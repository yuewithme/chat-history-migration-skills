# Reporting

The main entry returns one status:

| Status | Behavior |
|---|---|
| `unchanged` | Exit without a new candidate or HTML report |
| `completed` | Publish and write `latest-result.html` |
| `action_required` | Keep raw state and final; write `latest.html` |

Run files are stored under `<root>/reports/runs/<plan-id>`.

Reports must be static, self-contained, and sanitized. Include only counts, phase, timestamps, hashes, paths, and safe diagnostics. Exclude chat content, titles, complete IDs, attachment names, credentials, request data, and signed URLs.

Prevent overlapping runs with `<root>/tool/auto-backup.lock`. Recover only a lock older than six hours.
