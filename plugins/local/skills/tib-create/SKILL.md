---
name: tib-create
version: 1.0.0
description: Scaffold a new TIB (Technical Implementation Brief — a lightweight ADR/RFC) from a template. Use when user says /local:tib-create, "create a TIB", "new TIB", "draft an ADR", "start a design doc", or "write an RFC". Takes a decision title as argument; pre-fills date, author, and ID, leaves the rest for the user to write.
---

# /local:tib-create — Scaffold a New TIB

Create a new TIB (Technical Implementation Brief) markdown file from a template. A TIB is a lightweight ADR/RFC — a dated record of a technical decision, its motivation, alternatives considered, and rollout plan. Once written, it can be fed into `/local:extract-plan` to generate a Linear project from it.

## Arguments

- `$ARGUMENTS` should contain: `<decision-title>` (free-form, e.g. `"Adopt token-bucket rate limiting"`)
- If empty, ask: _"What's the decision title for this TIB?"_

## Instructions

### Step 1: Resolve metadata

Derive these values:

- **TITLE** — from `$ARGUMENTS` (or the user's answer). Used verbatim in the doc heading.
- **DATE** — today's date, as `YYYY-MM-DD`:
  ```bash
  DATE=$(date +%Y-%m-%d)
  ```
- **AUTHOR** — the user's git/GitHub identity:
  ```bash
  # Prefer GitHub @-handle when available; fall back to git config user.name
  AUTHOR="@$(gh api user --jq .login 2>/dev/null)" || AUTHOR=$(git config user.name)
  ```
- **SLUG** — a kebab-case slug derived from the title (lowercase, alphanumerics + hyphens, max ~60 chars). E.g. `"Adopt token-bucket rate limiting"` → `adopt-token-bucket-rate-limiting`.

### Step 2: Pick the output directory

Default location: `docs/tibs/`.

- If `docs/tibs/` exists at the repo root, use it.
- Else if any of `docs/rfcs/`, `docs/adrs/`, `docs/architecture/`, `docs/decisions/` exist, use the first match and tell the user which.
- Else create `docs/tibs/` and use that.

Final path: `<dir>/TIB-<DATE>-<SLUG>.md` (e.g. `docs/tibs/TIB-2026-05-19-adopt-token-bucket-rate-limiting.md`).

If a file with that exact name already exists, ask the user whether to overwrite, append a numeric suffix (`-2`, `-3`, …), or pick a different slug.

### Step 3: Materialize the template

Read the template:

```
${CLAUDE_PLUGIN_ROOT}/skills/tib-create/template.md
```

Substitute the three placeholders:

- `__TITLE__` → resolved TITLE
- `__DATE__`  → resolved DATE (substitute **all** occurrences, including in the H1 heading)
- `__AUTHOR__` → resolved AUTHOR (e.g. `@octocat` or `Jane Doe`)

Write the result to the path resolved in Step 2.

Use the Write tool — don't shell out to `sed`, because the body contains `_`, `|`, and `[`/`]` characters that interact awkwardly with sed delimiters across shells.

### Step 4: Confirm and offer next steps

Print:

```
TIB created: <relative-path>

Next steps:
  1. Fill in Context, Goals/Non-Goals, Proposed Solution, and Considered Alternatives.
  2. Share for review (PR, doc tool, Slack).
  3. When the decision is accepted, flip Status to `Accepted` and (optionally) run:
        /local:extract-plan <relative-path>
     to generate a Linear project with milestones and issues from the doc.
```

Then, if `code` or `cursor` is on the PATH and the environment is interactive, ask whether to open the file. Don't open it automatically.

### Important notes

- Default `Status` is `Proposed` — the user changes it to `Accepted` once the decision is approved.
- TIB IDs use **CalVer** (`YYYY-MM-DD`), not sequential numbering. Two TIBs drafted the same day get different slugs (and a numeric suffix if titles also collide).
- The template references your project's central conventions doc generically (`AGENTS.md` or `CLAUDE.md`) — don't substitute that to a specific one; let the author choose.
- Do NOT commit the new file or create a branch — this skill creates a single markdown file and stops.
