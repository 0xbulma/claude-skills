---
name: release-integrity
version: 1.0.0
kind: conditional
trigger: <HAS_RELEASE>
applies: |
  The project's release / publish flow spec, if any (look for AGENTS.md /
  CLAUDE.md sections on release automation, publish flow, plus SECURITY.md).
  When the project has no codified rule, fall back to this persona's body.
out-of-scope:
  - GitHub Actions workflow injection / action pinning / permissions — see ci-security.
  - Lockfile drift, .npmrc, dependency hygiene — see dependencies.
  - Code quality of build/test scripts themselves — see code-quality.
  - Test coverage of the publish flow — see test-coverage.
focus: |
  Publish-flow integrity (provenance, auth tokens), release-commit signing,
  write-token hardening, Changesets / release-bot wiring, deployment workflows.
severity-guidance: |
  Replacing signed commit identity with a local git commit → critical.
  Provenance opt-out on existing-provenance package → high. Unsigned release
  commits / unguarded write-tokens → high → critical depending on blast radius.
---

# Release Integrity

Releases push artifacts under the org's identity. A bad release workflow can publish a poisoned package or lose provenance. This persona reviews diffs that touch the publish / release / deploy surface.

## Run-time setup

Discover supplemental rubric skills via Bash:

```bash
# Conditional on the diff touching Vercel deploy surface.
if grep -lE "vercel\\.json|vercel (deploy|--prod|env|projects)" <CHANGED_FILES> >/dev/null 2>&1; then
  DEPLOY_RUBRIC=$(find ~/.claude -type f -name SKILL.md -path "*deploy-to-vercel*" 2>/dev/null | head -1)
  VERCEL_CLI_RUBRIC=$(find ~/.claude -type f -name SKILL.md -path "*vercel-cli-with-tokens*" 2>/dev/null | head -1)
fi
```

For each rubric variable that resolves to a non-empty path, Read the file in full and print `Loaded conditional skill: <name>`. For each that resolved empty, log degradation and continue with the inline rubric.

## Trigger

Fires when `<HAS_RELEASE>` is true — any changed file matches:

- `.changeset/**` (changeset entries, changesets config)
- Any `package.json` whose `scripts.*publish*` / `scripts.*release*` / `scripts.*deploy*` field is modified
- `vercel.json`
- Any file containing `changeset publish`, `npm publish`, `pnpm publish`, `gh release create`, `vercel deploy`, or `vercel --prod`

## Prompt must include

### Publish-flow integrity (HIGH → CRITICAL)

- `npm publish` / `pnpm publish` invocations: confirm `--provenance` is set (or that publishing happens via Changesets' provenance-aware path). Loss of provenance on an existing-provenance package is a downgrade.
- Authentication: confirm publishes use an org-scoped `NODE_AUTH_TOKEN` / `NPM_TOKEN`, not a personal access token; flag PATs.
- Tag scope: a workflow that previously only published to `next` now publishing to `latest` (or vice-versa) — surface as a release-flow change for human sign-off.
- New workflows that publish — require explicit dry-run path and a maintainer-approval gate (`environment:` with required reviewers) before the publish step.
- Provenance / SBOM toggles: any change that disables `--provenance` or removes a SLSA/SBOM emit step → **medium** finding minimum, **high** if the package is in the runtime/peer surface.

### Release-commit signing & write-token hardening (HIGH → CRITICAL)

- Replacing a `createCommitOnBranch` GraphQL invocation with a local `git commit` + `git push` from a workflow (loss of GitHub-signed identity). **Critical**.
- Minting a write-scoped GitHub App token (or any `permissions: contents: write` step) **without first** verifying the checksum and `$PATH` of the trusted helper(s) that step will execute. **High**.
- Skipping truncation of `$GITHUB_ENV` / `$GITHUB_PATH` immediately before a write-scoped step. (Inheriting state from earlier untrusted steps is a privilege-escalation path.) **High**.
- Allowing `.git/hooks/` to contain any file other than `*.sample` at the start of a release job. **Critical**.
- Removing the forced trusted `$PATH` or the explicit `RELEASE_BRANCH` guard from the write-token step. **High**.
- Adding a `git commit` / `git tag` invocation in a release workflow that doesn't first set `github-actions[bot]` (or another known signed identity) as the repo-local git identity — `Committer identity unknown` failures and unsigned tags are both downstream consequences. **Medium** when only tags are affected; **high** when commits are affected.

### Changesets / release-bot wiring

- `.changeset/config.json` changes — fixed-version, linked-package, baseBranch, or commit changes alter what gets shipped. Flag for human review on every change.
- New release workflows or release-bot actions — they typically hold elevated tokens; require pinned SHAs and explicit `permissions:`.
- Removed gating: if a previously-required check (lint, test, fork-suite) is dropped from the release workflow's `needs:`, flag as **high**.

## Output expectations

- Return findings in the same JSON shape as every other persona: `[{severity, file, line, description}]`.
- `description` must include both the *what* (concrete excerpt from the diff) and the *how to fix*. Generic warnings without a fix are not actionable.
- If no release-integrity concerns survive the diff scope, return `[]`.
