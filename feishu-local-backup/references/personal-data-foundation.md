# Personal data foundation

## Purpose

Build a long-lived personal data foundation that preserves context, supports future reasoning, and can be reprocessed by better AI systems. Collection is broad; activation into the knowledge layer is selective; deletion is exceptional and audited.

## Evaluate value, not category

Judge each item against the current owner's profile and the actual content:

1. Personal relevance: connection to the owner's experience, goals, work, learning, relationships, or decisions.
2. Reusability: likelihood of helping future reasoning, creation, recall, or decisions.
3. Uniqueness: information not easily reconstructed from public or duplicate sources.
4. Information density: substantive knowledge versus decoration, empty templates, or repeated assets.
5. Timeliness: whether age reduces utility and whether historical context remains useful.
6. Extractability: whether useful text, structure, transcript, OCR, or metadata can be preserved for AI use.
7. Provenance: source, date, owner, hierarchy, and context needed to interpret the item reliably.
8. Storage cost: bytes, duplication, and format friction relative to retained knowledge value.

Do not use a universal topic allowlist or denylist. A product guide, marketing artifact, family photo, or old policy can be valuable for one owner and irrelevant for another.

## Decision procedure

1. Apply explicit stable-ID keep/exclude decisions from the archive profile.
2. Read the title, hierarchy, metadata, and available text.
3. When text is absent or insufficient, inspect representative attachments. For a repeated homogeneous set, document the sampling method.
4. Separate knowledge value from container value. A useful PDF may become Markdown while its large binary is removed; an image may be the only source and must remain until OCR is validated.
5. Record one of the four actions with evidence and rationale.
6. Preserve uncertain items as `review`; do not turn uncertainty into deletion.

## Evidence requirements

- `keep_knowledge`: cite the useful content or explicit owner preference.
- `extract_then_remove_binary`: identify the validated replacement path and confirm it preserves the needed content.
- `review`: state what remains unknown and what inspection would resolve it.
- `exclude`: require `content_inspected: true`, a concrete personal-relevance rationale, exact targets, explicit authorization, and durable redownload prevention.

Folder names, extensions, file size, and keyword matches can prioritize review but cannot by themselves justify `exclude`.

## Learning without overgeneralizing

Store confirmed judgments in the selected archive, scoped by stable ID or source. Promote only reusable process lessons into the Skill. Never promote a tenant's rejected titles, products, departments, or topics into global policy.

When the owner's goals change, append a dated profile revision and re-evaluate `review` items. Do not silently reinterpret historical deletion decisions.
