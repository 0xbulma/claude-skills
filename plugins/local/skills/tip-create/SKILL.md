---
name: tip-create
version: 0.2.0
description: Scaffold a new TIP (Technical Implementation Plan — the concrete "how to build" doc that pairs with one or more TIBs). Use when user says /local:tip-create, "create a TIP", "new implementation plan", "scaffold doc-as-code", or "implementation template". Takes a feature title; optionally one or more --tib path arguments to seed Context/Goals/Non-Goals. Auto-maintains Sibling TIP(s) back-links across TIPs that share a parent TIB. Bakes a per-block TDD/format/lint/typecheck/test loop into every implementation phase.
---

# /local:tip-create — Scaffold a New TIP

Create a new TIP (Technical Implementation Plan) markdown file from a template. A TIP is the *mutable*, concrete companion to a [[tib-create]] TIB: it spells out files to modify, phased steps as checkboxes, test plans, acceptance criteria, and a verification checklist. One TIB can have many TIPs (the decision spawns multiple coordinated slices); occasionally one TIP cites multiple TIBs (the slice legitimately spans more than one decision).

## Arguments

`$ARGUMENTS` accepts:

- `<feature-title>` — required, free-form (e.g. `"Streaming reflection UI"`). Everything before the first `--` flag.
- `--tib <path>` — optional, **repeatable**. Path to a TIB markdown file. Seeds Context / Goals / Non-Goals and back-links siblings.
- `--dir <path>` — optional. Override the output directory.

If `$ARGUMENTS` is empty, ask: _"What's the feature title for this TIP?"_

## Instructions

### Step 1: Parse arguments

Split `$ARGUMENTS` on `--` flags:

- Everything before the first `--` is the **title** (trim whitespace).
- Each `--tib <path>` adds an entry to `TIB_PATHS` (preserve order).
- `--dir <path>` sets `OUT_DIR_OVERRIDE`.

Reject the call if the title is empty or only whitespace.

### Step 2: Resolve metadata

- **TITLE** — from arguments.
- **DATE** — `DATE=$(date +%Y-%m-%d)`.
- **AUTHOR** — same logic as `tib-create`:
  ```bash
  AUTHOR="@$(gh api user --jq .login 2>/dev/null)" || AUTHOR=$(git config user.name)
  ```
- **SLUG** — kebab-case of the title (lowercase, alphanumerics + hyphens, max ~60 chars).
- **FILENAME** — `TIP-<DATE>-<SLUG>.md`.

### Step 3: Resolve output directory

If `--dir` was given, use it (create if missing). Otherwise, search for an existing dir in this order and use the first match:

1. `docs/tips/`
2. `docs-as-code/`
3. `docs/`

If none exist, create `docs/tips/` and use that. Tell the user which path you picked.

Final path: `<OUT_DIR>/<FILENAME>`. If the file already exists, ask whether to overwrite, append a numeric suffix (`-2`, `-3`, …), or pick a different slug.

### Step 4: Seed from TIB(s), if any

For each path in `TIB_PATHS`:

1. Read the file. If it doesn't exist, abort with a clear error before writing anything.
2. Extract three sections by markdown heading:
   - `## Context` → body until the next `## `
   - `## Goals / Non-Goals` (or `## Goals & Non-Goals`) → body until the next `## `
3. Extract the TIB ID from the H1 (e.g. `# TIB-2026-05-12: Streaming reflection` → ID `TIB-2026-05-12`, title after the colon).

Build the seeded sections:

- **One TIB:** drop the body straight into the corresponding sections of the new TIP. Add a top note `_Seeded from <TIB-link>._` under each.
- **Multiple TIBs:** within each of Context / Goals / Non-Goals, emit one sub-heading per TIB:
  ```markdown
  ### From TIB-2026-05-12 — Streaming reflection
  <body extracted from that TIB>
  ```
  This preserves attribution and avoids a confusing merge.

Build the `Related TIB(s)` bullet list — one Markdown link per TIB, using the relative path from `<OUT_DIR>` to each TIB file.

If `TIB_PATHS` is empty, leave seeded sections as the template placeholders and set the `Related TIB(s)` row to `—`. Also remove the `__TIB_LINKS__` bullet line under `## References` in the template body.

### Step 5: Sniff Verification-Checklist commands

Locate the nearest `package.json` walking up from CWD to the repo root. If none, leave the five commands as bare placeholders (`format`, `lint`, `typecheck`, `build`, `test`).

If found:

1. Detect package manager:
   - `pnpm-lock.yaml` present → `pnpm` (exec: `pnpm exec`)
   - `yarn.lock` present → `yarn` (exec: `yarn exec`)
   - `bun.lockb` present → `bun run` (exec: `bunx`)
   - else → `npm run` (exec: `npx`)
2. For each of `typecheck`, `build`, `lint`, `test`: if the script exists in `package.json.scripts`, substitute `<pm> <script>`. If absent, leave the bare script name as a placeholder.
3. **Format command** (special-cased — used per-block by `tib-ship`):
   - If `scripts.format` exists → `<pm> format`.
   - Else if `scripts.format:fix` exists → `<pm> format:fix`.
   - Else if `devDependencies.@biomejs/biome` is present → `<exec> biome format --write .`.
   - Else if `devDependencies.prettier` is present → `<exec> prettier --write .`.
   - Else placeholder `format`.

### Step 6: Sibling sync — find and update sibling TIPs

Only relevant when `TIB_PATHS` is non-empty.

1. List existing TIPs in `<OUT_DIR>` matching `TIP-*.md`.
2. For each existing TIP, read its `Related TIB(s)` row. Parse the bullet list back into TIB IDs (or paths).
3. A sibling = any existing TIP that shares **at least one** TIB ID with the new TIP.
4. Build `SIBLING_TIP_LINKS` — Markdown links to each sibling, relative to `<OUT_DIR>`.
5. After writing the new TIP (Step 7), open each sibling file and update *its* `Sibling TIP(s)` row to include a link to the new TIP. Preserve any existing siblings; deduplicate by file path. Touch nothing else in the file.

If no siblings are found, set `SIBLING_TIP_LINKS` to `—`.

### Step 7: Materialize the template

Read `${CLAUDE_PLUGIN_ROOT}/skills/tip-create/template.md` and substitute:

| Placeholder              | Value                                                                    |
| ------------------------ | ------------------------------------------------------------------------ |
| `__TITLE__`              | TITLE                                                                    |
| `__DATE__`               | DATE (all occurrences, including the H1)                                 |
| `__AUTHOR__`             | AUTHOR                                                                   |
| `__TIB_LINKS__`          | Bullet list of `--tib` links, or `—` if none                             |
| `__SIBLING_TIP_LINKS__`  | Bullet list of sibling-TIP links, or `—` if none                         |
| `__FORMAT_CMD__`         | From Step 5 (e.g. `pnpm format` / `pnpm exec biome format --write .`)    |
| `__LINT_CMD__`           | From Step 5                                                              |
| `__TYPECHECK_CMD__`      | From Step 5 (e.g. `pnpm typecheck`)                                      |
| `__BUILD_CMD__`          | From Step 5                                                              |
| `__TEST_CMD__`           | From Step 5                                                              |

If a seeded section was built in Step 4, splice it into the body in place of the corresponding placeholder block in the template.

Use the Write tool — don't shell out to `sed`. The body has `_`, `|`, `[`/`]`, and backticks that interact badly with sed delimiters.

### Step 8: Update sibling TIPs

For each sibling found in Step 6, read the file with Read, locate the `**Sibling TIP(s)**` row, and replace its value with the merged + deduplicated bullet list (existing siblings + the new TIP). Write back with Edit. Do not modify any other line.

Idempotent guarantee: if a re-run produces the same sibling set, the file contents do not change.

### Step 9: Confirm and offer next steps

Print:

```
TIP created: <relative-path>
Related TIB(s): <list, or "—">
Siblings updated: <list of file paths, or "none">

Next steps:
  1. Fill in Overview, Technical Design, Files to Modify, Implementation Steps,
     Testing Strategy, Risks & Mitigations, and Acceptance Criteria.
  2. Set Status to "Approved" when reviewers sign off.
  3. As you ship, tick the Implementation Steps checkboxes and Verification
     Checklist items. Move Status to "In Progress" → "Shipped".
  4. Optionally, run /local:extract-plan <relative-path> to create Linear
     milestones + issues from this TIP.
```

Then, if `code` or `cursor` is on the PATH, ask whether to open the file. Don't open automatically.

### Important notes

- Default `Status` is `Draft` — the author moves it to `Approved` / `In Progress` / `Shipped` as the work progresses.
- TIP IDs use **CalVer** (`YYYY-MM-DD`), matching TIBs. Two TIPs drafted the same day get different slugs; identical titles get a numeric suffix.
- A TIP is *mutable* — unlike a TIB, you keep editing it during execution. The paired TIB remains frozen.
- 1 TIB → N TIPs is the normal case. 1 TIP → N TIBs is rare but legitimate (a slice that spans more than one decision).
- Do NOT commit, push, or branch — this skill creates one markdown file and (idempotently) touches sibling TIPs' header rows, nothing else.
