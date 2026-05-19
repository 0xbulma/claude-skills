#!/usr/bin/env bash
#
# install-prereqs.sh — idempotently install the 5 prereq skills used by the
# local conditional personas.
#
# Safe to run repeatedly. Each skill is only fetched if not already present
# at ~/.claude/skills/<name>/SKILL.md.
#
# Invoked by:
#   - SessionStart hook (silent, background)
#   - /local:setup skill (manual, verbose)
#
# Skill source: vercel-labs/agent-skills + addyosmani/web-quality-skills +
#               wshobson/agents + xixu-me/skills (skills.sh registry).
#

set -u  # do NOT set -e — we want to keep trying other skills if one fails
VERBOSE="${VERBOSE:-0}"

log() { [ "$VERBOSE" = "1" ] && echo "[local setup] $*" >&2; return 0; }

# Bail out gracefully if the user has no npx (no Node).
if ! command -v npx >/dev/null 2>&1; then
  log "npx not on PATH — skipping prereq install. Skills will degrade to inline rubrics."
  exit 0
fi

# Each line: <installed-skill-name-under-~/.claude/skills/> <owner/repo@skill-name>
# Most install names match the @skill-name; a few differ where upstream renamed.
PREREQS='vercel-react-best-practices       vercel-labs/agent-skills@vercel-react-best-practices
vercel-composition-patterns       vercel-labs/agent-skills@vercel-composition-patterns
vercel-react-native-skills        vercel-labs/agent-skills@vercel-react-native-skills
next-best-practices               vercel-labs/next-skills@next-best-practices
next-cache-components             vercel-labs/next-skills@next-cache-components
turborepo                         vercel/turborepo@turborepo
ai-sdk                            vercel/ai@ai-sdk
ai-elements                       vercel/ai-elements@ai-elements
streamdown                        vercel/streamdown@streamdown
web-design-guidelines             vercel-labs/agent-skills@web-design-guidelines
building-components               vercel/components.build@building-components
agent-browser                     vercel-labs/agent-browser@agent-browser
deploy-to-vercel                  vercel-labs/agent-skills@deploy-to-vercel
vercel-cli-with-tokens            vercel-labs/agent-skills@vercel-cli-with-tokens
find-skills                       vercel-labs/skills@find-skills
before-and-after                  vercel-labs/before-and-after@before-and-after
tailwind-design-system            wshobson/agents@tailwind-design-system
github-actions-docs               xixu-me/skills@github-actions-docs'

installed=0
skipped=0
failed=0

while IFS=' ' read -r name pkg; do
  [ -z "$name" ] && continue
  target="$HOME/.claude/skills/$name/SKILL.md"
  if [ -e "$target" ]; then
    log "✓ $name (already installed)"
    skipped=$((skipped + 1))
    continue
  fi
  log "→ installing $name from $pkg"
  if npx --yes skills add "$pkg" -g -y </dev/null >/dev/null 2>&1; then
    log "✓ $name installed"
    installed=$((installed + 1))
  else
    log "✗ $name install failed (continuing)"
    failed=$((failed + 1))
  fi
done <<< "$PREREQS"

log "summary: $installed installed, $skipped skipped, $failed failed"

# Always exit 0 — prereq install is best-effort. A failure should not block
# the user's session or their /local:setup invocation.
exit 0
