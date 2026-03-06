# noderef/noderef repository instructions

- This repo is a `pnpm` monorepo. Use `pnpm`, not `npm`.
- Main source areas are `apps/backend`, `apps/renderer`, and `packages/contracts`.
- Prefer small TypeScript changes over refactors.
- Keep changes scoped to the issue. Do not clean up unrelated code while you are there.
- Treat `dist/`, `resources/`, `node-src/`, `build-scripts/`, `_app_scaffolds/`, `.deploy-backend/`, and `apps/backend/src/ai/.generated/` as generated or external artifacts. Do not edit them manually.
- Do not touch `.env*`, `.runtime/`, `master.key`, `*.db*`, or any local runtime data.
- Be conservative around authentication, OIDC, encryption, stored credentials, and server connection logic. Minimal changes only.
- Do not change Prisma schema, migrations, Docker, Neutralino config, or release workflow files unless the issue is explicitly about those areas. If the issue requires one of those surfaces, stop and report that it needs human review.
- When changing request or response shapes, keep `packages/contracts`, backend RPC handlers, and renderer consumers in sync.
- For backend work, prefer changes under `apps/backend/src` and add or adjust tests under `apps/backend/tests` when behavior changes.
- For frontend work, prefer changes under `apps/renderer/src`. Only change locales or assets when the issue explicitly requires UI copy or asset updates.
- Default validation command is `pnpm test`.
- Run only the configured test command unless the issue explicitly requires another safe repo script.
- Do not run packaging, docker, installer, or release commands as part of normal issue work.
- Do not run `pnpm format`; avoid repo-wide rewrites.
- Preserve backward compatibility for stored user data, server settings, and RPC behavior unless the issue explicitly calls for a breaking change.
