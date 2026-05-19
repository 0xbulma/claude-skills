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
  PLUGIN_DIR="$REPO_ROOT/plugins/ben-pr"
  PLUGIN_MANIFEST="$PLUGIN_DIR/.claude-plugin/plugin.json"
  SKILLS_DIR="$PLUGIN_DIR/skills"
  PERSONAS_DIR="$PLUGIN_DIR/personas"
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

@test "four skills exist at expected paths" {
  [ -f "$SKILLS_DIR/fix/SKILL.md" ]
  [ -f "$SKILLS_DIR/review-gh/SKILL.md" ]
  [ -f "$SKILLS_DIR/review-local/SKILL.md" ]
  [ -f "$SKILLS_DIR/setup/SKILL.md" ]
}

@test "each SKILL.md has name matching its directory" {
  for skill in fix review-gh review-local setup; do
    skill_file="$SKILLS_DIR/$skill/SKILL.md"
    name=$(awk '/^---$/{f=!f; next} f && /^name:/{print $2; exit}' "$skill_file")
    [ "$name" = "$skill" ] || { echo "skill=$skill got name=$name" >&2; return 1; }
  done
}

@test "each SKILL.md has a non-empty description" {
  for skill in fix review-gh review-local setup; do
    skill_file="$SKILLS_DIR/$skill/SKILL.md"
    desc=$(awk '/^---$/{f=!f; next} f && /^description:/{sub(/^description: */,""); print; exit}' "$skill_file")
    [ -n "$desc" ] || { echo "skill=$skill has empty description" >&2; return 1; }
  done
}

@test "each SKILL.md has a semver version" {
  for skill in fix review-gh review-local setup; do
    skill_file="$SKILLS_DIR/$skill/SKILL.md"
    version=$(awk '/^---$/{f=!f; next} f && /^version:/{print $2; exit}' "$skill_file")
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || { echo "skill=$skill version=$version is not semver" >&2; return 1; }
  done
}

@test "each persona has a semver version" {
  for persona_file in "$PERSONAS_DIR"/*.md; do
    version=$(awk '/^---$/{f=!f; next} f && /^version:/{print $2; exit}' "$persona_file")
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || { echo "$persona_file version=$version is not semver" >&2; return 1; }
  done
}

@test "no leaked @morpho-org references in plugins/" {
  run grep -rn '@morpho-org' "$PLUGIN_DIR"
  # grep returns 1 when no match — that's what we want.
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

@test "no leaked ~/.claude/skills/ hardcoded paths in personas + lib + skills" {
  # Hardcoded ~/.claude/skills/<name>/SKILL.md was the old standalone-install pattern.
  # Plugin layout discovers paths via Bash `find` — see CLAUDE.md.
  # bin/install-prereqs.sh and skills/setup/SKILL.md legitimately reference this path
  # because that's exactly where `npx skills add` installs to.
  run grep -rn '~/\.claude/skills/' \
    "$PLUGIN_DIR/personas" \
    "$PLUGIN_DIR/lib" \
    "$PLUGIN_DIR/skills/fix" \
    "$PLUGIN_DIR/skills/review-gh" \
    "$PLUGIN_DIR/skills/review-local"
  [ "$status" -ne 0 ]
}

@test "persona inventory is exactly 10 files" {
  count=$(find "$PERSONAS_DIR" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d ' ')
  [ "$count" = "10" ]
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
  # The 3 main skills are model-invokable; `setup` is intentionally
  # disable-model-invocation: true and may not appear in the listing.
  run claude --plugin-dir "$PLUGIN_DIR" -p "List the plugin slash commands you can see. Just print their names." 2>&1
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ben-pr:fix"
  echo "$output" | grep -q "ben-pr:review-gh"
  echo "$output" | grep -q "ben-pr:review-local"
}
