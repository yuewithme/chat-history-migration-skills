# Public Skill Collection

- This repository is the public, installable release surface for three local-first chat archive Skills.
- Treat each top-level Skill directory as an independently installable package; keep its `SKILL.md` name equal to the directory name.
- Keep runtime account data, logs, credentials, personal paths, private workspace memory, and real fixtures out of this repository.
- Daily development happens in private source repositories. Changes here must represent a reviewed release snapshot, not an unverified parallel implementation.
- Keep the root README concise and user-facing. Put Agent workflow details in `SKILL.md` and load deeper material from `references/` only when needed.
- Before committing, run `powershell -NoProfile -File tools/validate-release.ps1` and the narrow tests for every changed Skill.
- Do not weaken validation or delete recovery state to make a release pass.
