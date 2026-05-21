#!/usr/bin/env bats
#
# Validates the shape of this repo as a Claude Code plugin marketplace.
# Run: bats test/plugin.bats
#
# Install bats with: brew install bats-core
#

setup() {
  # Resolve repo root from this test file's location.
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  MARKETPLACE="$REPO_ROOT/.claude-plugin/marketplace.json"
  PLUGIN_DIR="$REPO_ROOT/plugins/local"
  PLUGIN_MANIFEST="$PLUGIN_DIR/.claude-plugin/plugin.json"
  SKILLS_DIR="$PLUGIN_DIR/skills"
  AGENTS_DIR="$SKILLS_DIR/pr-review-engine/agents"
  SKILLS_ALL="pr-fix pr-review-gh pr-review-local setup pr-create extract-plan tib-create pr-switch tip-create tib-ship pr-review-engine"
}

@test "marketplace.json is valid JSON" {
  run jq empty "$MARKETPLACE"
  [ "$status" -eq 0 ]
}

@test "marketplace.json has required fields" {
  run jq -e '.name and .owner.name and (.plugins | length > 0)' "$MARKETPLACE"
  [ "$status" -eq 0 ]
}

@test "plugin.json is valid JSON" {
  run jq empty "$PLUGIN_MANIFEST"
  [ "$status" -eq 0 ]
}

@test "plugin.json has required fields" {
  run jq -e '.name and .description and .version' "$PLUGIN_MANIFEST"
  [ "$status" -eq 0 ]
}

@test "eleven skills exist at expected paths" {
  for skill in $SKILLS_ALL; do
    [ -f "$SKILLS_DIR/$skill/SKILL.md" ] || { echo "missing $SKILLS_DIR/$skill/SKILL.md" >&2; return 1; }
  done
}

@test "each SKILL.md has name matching its directory" {
  for skill in $SKILLS_ALL; do
    skill_file="$SKILLS_DIR/$skill/SKILL.md"
    name=$(awk '/^---$/{f=!f; next} f && /^name:/{print $2; exit}' "$skill_file")
    [ "$name" = "$skill" ] || { echo "skill=$skill got name=$name" >&2; return 1; }
  done
}

@test "each SKILL.md has a non-empty description" {
  for skill in $SKILLS_ALL; do
    skill_file="$SKILLS_DIR/$skill/SKILL.md"
    desc=$(awk '/^---$/{f=!f; next} f && /^description:/{sub(/^description: */,""); print; exit}' "$skill_file")
    [ -n "$desc" ] || { echo "skill=$skill has empty description" >&2; return 1; }
  done
}

@test "each SKILL.md has a semver version" {
  for skill in $SKILLS_ALL; do
    skill_file="$SKILLS_DIR/$skill/SKILL.md"
    version=$(awk '/^---$/{f=!f; next} f && /^version:/{print $2; exit}' "$skill_file")
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || { echo "skill=$skill version=$version is not semver" >&2; return 1; }
  done
}

@test "each agent has a semver version" {
  for agent_file in "$AGENTS_DIR"/*.md; do
    version=$(awk '/^---$/{f=!f; next} f && /^version:/{print $2; exit}' "$agent_file")
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || { echo "$agent_file version=$version is not semver" >&2; return 1; }
  done
}

@test "no leaked @morpho-org references in plugins/" {
  run grep -rn '@morpho-org' "$PLUGIN_DIR"
  # grep returns 1 when no match — that's what we want.
  [ "$status" -ne 0 ]
}

@test "no leaked 'morpho' references anywhere in plugins/" {
  # Skills imported from morpho-org/sdks must be fully repo-agnostic.
  # No exceptions — including author/owner metadata.
  run grep -rni --exclude-dir=node_modules 'morpho' "$PLUGIN_DIR"
  [ "$status" -ne 0 ]
}

@test "no leaked personal-name references in plugins/" {
  # Only the public 0xbulma handle is permitted.
  run grep -rn 'Benjamin A\|benjamin@' "$PLUGIN_DIR"
  [ "$status" -ne 0 ]
}

@test "no leaked <HOME> template tokens in plugins/" {
  run grep -rn '<HOME>' "$PLUGIN_DIR"
  [ "$status" -ne 0 ]
}

@test "no leaked /.agents/ absolute paths in plugins/" {
  run grep -rn '/\.agents/' "$PLUGIN_DIR"
  [ "$status" -ne 0 ]
}

@test "no leaked ~/.claude/skills/ hardcoded paths in agents + skills" {
  # Hardcoded ~/.claude/skills/<name>/SKILL.md was the old standalone-install pattern.
  # Plugin layout discovers paths via Bash `find` — see CLAUDE.md.
  # bin/install-prereqs.sh and skills/setup/SKILL.md legitimately reference this path
  # because that's exactly where `npx skills add` installs to.
  run grep -rn '~/\.claude/skills/' \
    "$AGENTS_DIR" \
    "$SKILLS_DIR/pr-review-engine/SKILL.md" \
    "$SKILLS_DIR/pr-fix" \
    "$SKILLS_DIR/pr-review-gh" \
    "$SKILLS_DIR/pr-review-local"
  [ "$status" -ne 0 ]
}

@test "agent inventory is exactly 15 files" {
  # 6 baseline + 9 conditional. Three combos (ci-release-security,
  # ui-styling-accessibility, code-simplifier-performance) split per
  # TIP-2026-05-20-persona-refinement: 11 - 3 + 7 = 15.
  count=$(find "$AGENTS_DIR" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d ' ')
  [ "$count" = "15" ]
}

@test "list-fix-rubric-agents.sh returns exit 0 + empty stdout when no agent matches" {
  # Regression test: the script wraps `grep -l ... | sort` in `{ ... || true; }`
  # so a no-match doesn't propagate as a pipefail exit. A regression removing
  # the `|| true` would crash every caller (pr-fix, bats invariant). This test
  # locks the contract: empty agents dir → exit 0, empty stdout.
  EMPTY_DIR="$BATS_TEST_TMPDIR/empty-agents"
  mkdir -p "$EMPTY_DIR"
  # An agents dir with .md files but no `## Fix rubric` sections.
  printf '# placeholder\n' > "$EMPTY_DIR/placeholder.md"

  run "$SKILLS_DIR/pr-review-engine/scripts/list-fix-rubric-agents.sh" "$EMPTY_DIR"
  [ "$status" -eq 0 ] || { echo "expected exit 0; got $status" >&2; return 1; }
  [ -z "$output" ]    || { echo "expected empty stdout; got: $output" >&2; return 1; }
}

@test "pr-fix fix-rubric agent set is exactly the five expected" {
  # pr-fix's confidence gate (Step 6a) walks $AGENTS_DIR for files with a
  # `## Fix rubric` section. Locks the set so a fix-rubric section can't
  # be silently added/removed without an explicit test update.
  # The bundled script `scripts/list-fix-rubric-agents.sh` is the single
  # source of truth for the discovery; this test pins its output.
  expected="ci-security dependencies docs release-integrity web3"
  actual=$("$SKILLS_DIR/pr-review-engine/scripts/list-fix-rubric-agents.sh" \
           | xargs -n1 basename \
           | sed 's/\.md$//' \
           | sort | tr '\n' ' ' | sed 's/ $//')
  [ "$actual" = "$expected" ] || { echo "expected: $expected"; echo "got:      $actual" >&2; return 1; }
}

@test "each agent has name matching its filename" {
  # Mirrors the same invariant we enforce on top-level skills (line 46-52).
  # Catches: a rename (like code-quality → correctness) that updates the
  # filename but leaves the frontmatter `name:` at the old value.
  for agent_file in "$AGENTS_DIR"/*.md; do
    name=$(awk '/^---$/{f=!f; next} f && /^name:/{print $2; exit}' "$agent_file")
    expected=$(basename "$agent_file" .md)
    [ "$name" = "$expected" ] || { echo "agent=$expected got name=$name" >&2; return 1; }
  done
}

@test "each conditional agent declares a trigger" {
  # `kind: conditional` agents must have `trigger:` so the engine knows
  # when to fire them. `kind: baseline` agents must not (they always fire).
  for agent_file in "$AGENTS_DIR"/*.md; do
    kind=$(awk '/^---$/{f=!f; next} f && /^kind:/{print $2; exit}' "$agent_file")
    trigger=$(awk '/^---$/{f=!f; next} f && /^trigger:/{print; exit}' "$agent_file")
    case "$kind" in
      baseline)
        [ -z "$trigger" ] || { echo "$agent_file: kind=baseline but has trigger=$trigger" >&2; return 1; }
        ;;
      conditional)
        [ -n "$trigger" ] || { echo "$agent_file: kind=conditional but no trigger declared" >&2; return 1; }
        ;;
      *)
        echo "$agent_file: kind=$kind is not baseline|conditional" >&2; return 1
        ;;
    esac
  done
}

@test "no XML angle brackets anywhere in skill or agent frontmatter" {
  # Anthropic Skills guide, Reference B: "Forbidden in frontmatter: XML
  # angle brackets (< >) - security restriction". The engine and consumer
  # skills, plus every agent file, must be free of `<` / `>` inside the
  # `---` ... `---` frontmatter block. Body prose may still use the
  # brackets to mark template placeholders — that's not in scope here.
  set +e
  bad=""
  while IFS= read -r f; do
    found=$(awk '
      # Only enter frontmatter mode when the FIRST non-empty line is ---.
      # Markdown horizontal rules (--- inside body) must not increment state.
      NR == 1 && /^---$/ { in_fm = 1; next }
      in_fm && /^---$/   { exit }
      in_fm && /[<>]/    { printf "%s:%d:%s\n", FILENAME, NR, $0 }
    ' "$f")
    if [ -n "$found" ]; then
      bad="${bad}\n${found}"
    fi
  done < <(find "$SKILLS_DIR" -type f -name '*.md')
  set -e
  [ -z "$bad" ] || { printf 'XML brackets found in frontmatter:%b\n' "$bad" >&2; return 1; }
}

@test "engine ships scripts/ with the three bundled helpers" {
  # The Anthropic Skills guide (p. 26) recommends scripting deterministic
  # logic instead of expressing it only in language. The three helpers
  # implement the diff-line build, the finding validator, and the
  # fix-rubric agent discovery — locking the file list catches a future
  # edit that removes any of them.
  SCRIPTS_DIR="$SKILLS_DIR/pr-review-engine/scripts"
  [ -x "$SCRIPTS_DIR/build-changed-lines.sh" ]   || { echo "missing/non-executable: build-changed-lines.sh" >&2; return 1; }
  [ -x "$SCRIPTS_DIR/validate-findings.py" ]     || { echo "missing/non-executable: validate-findings.py" >&2; return 1; }
  [ -x "$SCRIPTS_DIR/list-fix-rubric-agents.sh" ]|| { echo "missing/non-executable: list-fix-rubric-agents.sh" >&2; return 1; }
}

@test "engine ships the three new references/ files" {
  REFS_DIR="$SKILLS_DIR/pr-review-engine/references"
  for f in changed-lines.md scope-filter.md calibration.md; do
    [ -f "$REFS_DIR/$f" ] || { echo "missing reference: $REFS_DIR/$f" >&2; return 1; }
  done
}

@test "engine and setup skills set disable-model-invocation: true" {
  # These two skills are invoked by other skills (engine) or by the user
  # via a separate path (setup). They must not appear in the slash-command
  # menu — disable-model-invocation: true is what enforces that.
  for skill in pr-review-engine setup; do
    flag=$(awk '/^---$/{f=!f; next} f && /^disable-model-invocation:/{print $2; exit}' "$SKILLS_DIR/$skill/SKILL.md")
    [ "$flag" = "true" ] || { echo "$skill/SKILL.md missing disable-model-invocation: true (got: $flag)" >&2; return 1; }
  done
}

@test "engine SKILL.md documents the scope-filter contract" {
  # The Step 6 sub-step 1 contract names three drop categories and the
  # CHANGED_LINES tolerance window. Locks these in so a future edit
  # that removes one of the structural filters fails the test.
  # Identifiers in the engine prose are written without `< >` brackets
  # since the Anthropic Skills guide forbids brackets in frontmatter
  # — the body inherits the same convention for consistency.
  engine="$SKILLS_DIR/pr-review-engine/SKILL.md"
  grep -q 'CHANGED_LINES' "$engine"          || { echo "engine missing CHANGED_LINES contract" >&2; return 1; }
  grep -q 'DROPPED_OUT_OF_SCOPE' "$engine"   || { echo "engine missing DROPPED_OUT_OF_SCOPE counter" >&2; return 1; }
  grep -q 'DROPPED_PRE_EXISTING' "$engine"   || { echo "engine missing DROPPED_PRE_EXISTING counter" >&2; return 1; }
  grep -q 'DROPPED_DOC_EXAMPLE' "$engine"    || { echo "engine missing DROPPED_DOC_EXAMPLE counter" >&2; return 1; }
  grep -q 'WHAT:'  "$engine"                 || { echo "engine missing WHAT: schema marker" >&2; return 1; }
  grep -q 'FIX:'   "$engine"                 || { echo "engine missing FIX: schema marker" >&2; return 1; }
  grep -q '±15'    "$engine"                 || { echo "engine missing the ±15 adjacent-code tolerance window" >&2; return 1; }
}

@test "every references/*.md pointer in agents resolves to a real file" {
  REFS_DIR="$SKILLS_DIR/pr-review-engine/references"
  # Every "Cross-check `references/X.md`" pointer in an agent body must
  # resolve to an actual file. Catches: a references file renamed or
  # deleted without updating the citing agents.
  missing=""
  for ref in $(grep -rho 'references/[a-z-]*\.md' "$AGENTS_DIR" | sort -u); do
    [ -f "$REFS_DIR/${ref#references/}" ] || missing="$missing $ref"
  done
  [ -z "$missing" ] || { echo "agents point at non-existent references:$missing" >&2; return 1; }
}

@test "references/*.md backlinks are bidirectional" {
  REFS_DIR="$SKILLS_DIR/pr-review-engine/references"
  # Every agent listed in a references file's `## Consumers` section
  # must actually carry a "Cross-check `references/X.md`" pointer line.
  # Catches: a Consumers entry that survives a rename/refactor when
  # the agent's pointer was removed.
  #
  # Only treat backticked tokens as consumer names if a matching agent
  # file actually exists under $AGENTS_DIR/<name>.md — otherwise we'd
  # pick up incidental code-formatted prose like `eval()` or `0x...`.
  for ref_file in "$REFS_DIR"/secrets.md "$REFS_DIR"/injection.md "$REFS_DIR"/effect-cleanup.md; do
    ref_name=$(basename "$ref_file")
    consumers=$(awk '/^## Consumers/,EOF' "$ref_file" | grep -oE '`[a-z][a-z0-9-]*`' | tr -d '`' | sort -u)
    for c in $consumers; do
      [ -f "$AGENTS_DIR/$c.md" ] || continue
      grep -q "references/$ref_name" "$AGENTS_DIR/$c.md" 2>/dev/null \
        || { echo "$ref_file lists $c as consumer but $AGENTS_DIR/$c.md has no 'references/$ref_name' pointer" >&2; return 1; }
    done
  done
}

@test "hooks.json and install-prereqs.sh exist and are wired up" {
  [ -f "$PLUGIN_DIR/hooks/hooks.json" ]
  [ -x "$PLUGIN_DIR/bin/install-prereqs.sh" ]
  run jq -e '.hooks.SessionStart' "$PLUGIN_DIR/hooks/hooks.json"
  [ "$status" -eq 0 ]
}

@test "no install.sh remaining at repo root" {
  [ ! -f "$REPO_ROOT/install.sh" ]
}

@test "local plugin-dir smoke install (skipped if claude CLI absent)" {
  command -v claude >/dev/null 2>&1 || skip "claude CLI not on PATH"

  # Non-interactive smoke: load the plugin and ask Claude to list skills.
  # The 9 model-invokable skills should appear; `setup` is intentionally
  # disable-model-invocation: true and may not appear in the listing.
  run claude --plugin-dir "$PLUGIN_DIR" -p "List the plugin slash commands you can see. Just print their names." 2>&1
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "local:pr-switch"
  echo "$output" | grep -q "local:pr-fix"
  echo "$output" | grep -q "local:pr-review-gh"
  echo "$output" | grep -q "local:pr-review-local"
  echo "$output" | grep -q "local:pr-create"
  echo "$output" | grep -q "local:extract-plan"
  echo "$output" | grep -q "local:tib-create"
  echo "$output" | grep -q "local:tip-create"
  echo "$output" | grep -q "local:tib-ship"
}
