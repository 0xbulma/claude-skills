# claude-skills

Personal Claude Code skills for PR review and PR fix workflows, plus the persona library they share. Repo-agnostic — works on any project.

## What's in here

```
.
├── README.md
├── install.sh                  # symlink + template-substitute into ~/.agents/ and ~/.claude/skills/
├── lib/
│   └── ben-pr-review-base.md   # shared Step 3–6 base for the review skills
├── personas/                   # one file per review focus area
│   ├── code-quality.md             # baseline
│   ├── silent-failure-hunter.md    # baseline
│   ├── documentation.md            # baseline
│   ├── test-coverage.md            # baseline
│   ├── code-simplifier-performance.md  # baseline
│   ├── web3-security.md            # conditional <HAS_WEB3>
│   ├── react-next-best-practices.md  # conditional <HAS_REACT>
│   ├── ui-styling-accessibility.md   # conditional <HAS_TAILWIND> OR <HAS_STYLING>
│   └── ci-release-security.md      # conditional <HAS_CI_RELEASE>
└── skills/
    ├── ben-pr-review-gh/SKILL.md       # /ben-pr-review-gh — local PR review, posts as GitHub COMMENT
    ├── ben-pr-review-local/SKILL.md    # /ben-pr-review-local — pre-PR local review, terminal-only
    └── ben-pr-fix/SKILL.md             # /ben-pr-fix — apply review comments, resolve conflicts, watch
```

## What the skills do

- **`/ben-pr-review-local`** — pre-PR local review against the working tree (committed + uncommitted). Terminal-only output. `--fix` applies mechanical fixes inline.
- **`/ben-pr-review-gh <PR>`** — review an open GitHub PR via the GraphQL API. Posts findings as a `COMMENT` review (never auto-approves). `--watch` re-runs on every new commit.
- **`/ben-pr-fix <PR>`** — read unresolved review comments, classify (actionable / question / praise / stale / etc.), apply fixes with confidence gating, push, reply, resolve. `--watch` runs a cron-driven fix loop.

All three review skills delegate Steps 3–6 to `lib/ben-pr-review-base.md`, which loops over `personas/*.md`. Baseline personas always fire; conditional personas fire when their trigger flag is true (detected from the diff in Step 4).

## Prerequisites

The three conditional UI / Web3 personas load these Anthropic marketplace skills at run time as their domain rubric. Install them first:

```bash
# In Claude Code (or via plugin install — your choice)
# 1. vercel-react-best-practices
# 2. vercel-composition-patterns
# 3. tailwind-design-system
```

If any are missing, the corresponding conditional persona will log a "skill not loaded" warning and degrade to its built-in rubric.

You also need:

- `gh` CLI authenticated (`gh auth status`) — for the GitHub PR skills.
- `git` ≥ 2.30 — for `--name-status --find-renames`.

## Install

```bash
git clone git@github.com:0xbulma/claude-skills.git
cd claude-skills
./install.sh
```

`install.sh` does three things:

1. Creates `~/.agents/lib/` and `~/.agents/personas/` if they don't exist.
2. Reads each file in `lib/` and `personas/`, substitutes `<HOME>` with your `$HOME`, and writes the result to `~/.agents/lib/` and `~/.agents/personas/`.
3. Same for each `skills/<name>/SKILL.md` → `~/.claude/skills/<name>/SKILL.md`.

> **Why copy-with-substitute instead of plain symlinks?** Sub-agents that Claude Code spawns receive prompts with paths inside; if they say `~/...` the sub-agent's Read tool may not expand the tilde. Copy-with-substitution writes the absolute `$HOME`-resolved path so sub-agents can `Read` them directly. Re-run `./install.sh` after pulling repo updates.

## How to update

Edit files in this repo. Then:

```bash
./install.sh        # re-sync ~/.agents/ and ~/.claude/skills/
```

For changes to the personas or the shared base, no skill restart is needed — Claude reads each file fresh on every review run.

## Architecture (one-screen mental model)

```
~/.claude/skills/ben-pr-review-{gh,local}/SKILL.md
                       │
                       └─→ delegates Steps 3–6 to ──┐
                                                    │
~/.claude/skills/ben-pr-fix/SKILL.md                │
                       │                            │
                       │                            v
                       │              ~/.agents/lib/ben-pr-review-base.md
                       │                            │
                       │                            └─→ loops over ──┐
                       │                                             │
                       │                                             v
                       │                          ~/.agents/personas/*.md
                       │                                  (9 files)
                       │                                             │
                       │                                             └─→ when conditional,
                       │                                                   load marketplace
                       │                                                   skill rubric
                       │
                       └─→ uses persona rubrics for its own confidence gate (Step 6a)
```

The pattern is one-way: skills depend on the lib, the lib loops over personas, personas may load marketplace skills as runtime rubric. Nothing points back up.

## License

MIT — fork, adapt, re-use freely. See [LICENSE](./LICENSE) if present.
