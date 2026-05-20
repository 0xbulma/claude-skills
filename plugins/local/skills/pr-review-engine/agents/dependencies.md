---
name: dependencies
version: 1.0.0
kind: conditional
trigger: <HAS_DEPS>
applies: |
  The project's dependency-hygiene spec, if any (look for AGENTS.md /
  CLAUDE.md sections on dependency policy, plus SECURITY.md). When the
  project has no codified rule, fall back to this persona's body.
out-of-scope:
  - GitHub Actions workflow security — see ci-security.
  - Release/publish flow and Changesets — see release-integrity.
  - Code quality of build/test scripts themselves — see correctness.
focus: |
  Lockfile drift, dependency hygiene, .npmrc / pnpm-workspace.yaml settings,
  typosquats, postinstall scripts.
severity-guidance: |
  Committed _authToken or non-default registry → critical (credential leak
  or supply-chain trust shift). Lockfile drift without justification → high
  (runtime/peer dep) or medium (devDep only). Typosquat-shaped name → high.
---

# Dependencies

The supply-chain surface. Bad lockfile-only changes can introduce attacker-controlled transitive deps; bad `.npmrc` entries can leak credentials or redirect installs to attacker registries. This persona reviews diffs that touch lockfiles, registry config, or workspace topology.

## Trigger

Fires when `<HAS_DEPS>` is true — any changed file matches:

- `pnpm-lock.yaml` / `package-lock.json` / `yarn.lock`
- `pnpm-workspace.yaml`
- `.npmrc` (any level)

## Prompt must include

### Lockfile drift / dependency hygiene

- Lockfile changes WITHOUT a corresponding `package.json` change — surface as a finding (could be a malicious lockfile-only attack, or legitimate transitive bump; ask for justification).
- New dependencies added to any `package.json`:
  - **High** when the dep ends up in `dependencies` or `peerDependencies` of a published package (runtime surface).
  - **Medium** when in `devDependencies` only.
  - In both cases, flag deps with `postinstall` / `preinstall` / `install` scripts in their package metadata (read from the registry or the lockfile entry), unpinned semver ranges (`^` / `~`) on a runtime dep, or names that look like typosquats of known packages.
- Removed deps: confirm the corresponding code that used them is also removed (otherwise the build silently relies on a hoisted transitive).

### `.npmrc` and `pnpm-workspace.yaml`

- Registry changes (`registry=` or `@scope:registry=`) — flag any non-`registry.npmjs.org` URL for explicit human review.
- `always-auth=true` or `_authToken=` committed to the repo — **critical** (credential leak). Cross-check `references/secrets.md`.
- New `auto-install-peers` / `strict-peer-dependencies` flips — flag as **medium**, surface impact on consumer install behavior.

## Output expectations

- Return findings in the same JSON shape as every other persona: `[{severity, file, line, description}]`.
- `description` must include both the *what* and the *how to fix*. Generic warnings without a fix are not actionable.
- If no dependency-hygiene concerns survive the diff scope, return `[]`.

## Fix rubric

(Consumed by `pr-fix` and by the engine when invoked with `<MODE>=fix`.)

Mechanical fixes only:
- Pin a runtime-`dependencies` entry's semver range from `^x.y.z` /
  `~x.y.z` to `x.y.z` when the project's spec requires exact pins.
- Remove a stray `_authToken=...` or non-default `registry=` line from
  `.npmrc` (rotate the credential out-of-band first; flag immediately).
- Re-pin a `pnpm-lock.yaml` / `package-lock.json` entry to the same
  version recorded in `package.json` when lockfile drift was caused by
  a stale install.

**Do not** auto-apply: adding new dependencies, bumping major versions,
or switching package managers — surface for human review.

Cross-check `references/secrets.md` for `_authToken` and embedded
credentials in registry URLs.
