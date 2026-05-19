#!/usr/bin/env bash
#
# install.sh — copy claude-skills content into ~/.agents/ and ~/.claude/skills/
#              with <HOME> substitution so absolute paths resolve correctly.
#
# Idempotent. Safe to re-run after pulling repo updates.
#
# Why copy-with-substitute instead of symlink:
#   Sub-agents spawned by Claude Code receive prompts containing paths to the
#   marketplace skill files (e.g. ~/.claude/skills/vercel-react-best-practices/SKILL.md).
#   The sub-agent's Read tool may not expand ~ on every harness version, so we
#   write the absolute $HOME-resolved path into each installed copy.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "Installing claude-skills from $REPO_DIR into \$HOME=$HOME"

# --- Sanity checks ---------------------------------------------------------

if [[ ! -d "$REPO_DIR/lib" || ! -d "$REPO_DIR/personas" || ! -d "$REPO_DIR/skills" ]]; then
  echo "ERROR: this doesn't look like a claude-skills checkout — missing lib/ personas/ or skills/." >&2
  echo "Expected: $REPO_DIR/{lib,personas,skills}" >&2
  exit 1
fi

# --- Targets ---------------------------------------------------------------

mkdir -p "$HOME/.agents/lib"
mkdir -p "$HOME/.agents/personas"
mkdir -p "$HOME/.claude/skills"

# --- Install lib/ and personas/ -------------------------------------------

install_file() {
  local src="$1"
  local dest="$2"
  mkdir -p "$(dirname "$dest")"
  # Use printf-friendly sed substitution. Use | as the delimiter so $HOME
  # (which may contain /) doesn't collide with sed's default /.
  sed "s|<HOME>|$HOME|g" "$src" > "$dest"
  echo "  → $dest"
}

echo ""
echo "Installing shared lib/ → ~/.agents/lib/"
for src in "$REPO_DIR/lib/"*.md; do
  [[ -e "$src" ]] || continue
  install_file "$src" "$HOME/.agents/lib/$(basename "$src")"
done

echo ""
echo "Installing personas/ → ~/.agents/personas/"
for src in "$REPO_DIR/personas/"*.md; do
  [[ -e "$src" ]] || continue
  install_file "$src" "$HOME/.agents/personas/$(basename "$src")"
done

# --- Install skills/<name>/SKILL.md ----------------------------------------

echo ""
echo "Installing skills/ → ~/.claude/skills/"
for skill_dir in "$REPO_DIR/skills/"*/; do
  [[ -e "$skill_dir" ]] || continue
  name="$(basename "$skill_dir")"
  src="$skill_dir/SKILL.md"
  [[ -f "$src" ]] || { echo "  ⚠ skipping $name (no SKILL.md)" >&2; continue; }
  dest_dir="$HOME/.claude/skills/$name"
  mkdir -p "$dest_dir"
  install_file "$src" "$dest_dir/SKILL.md"
done

# --- Marketplace-skill prereq check ----------------------------------------

echo ""
echo "Checking marketplace skill prerequisites..."
missing=0
for prereq in vercel-react-best-practices vercel-composition-patterns tailwind-design-system; do
  if [[ -f "$HOME/.claude/skills/$prereq/SKILL.md" ]]; then
    echo "  ✓ $prereq"
  else
    echo "  ✗ $prereq — not installed; the conditional persona that loads it will degrade to its built-in rubric"
    missing=$((missing + 1))
  fi
done

if [[ $missing -gt 0 ]]; then
  echo ""
  echo "Note: $missing marketplace skill(s) missing. Install them through Claude Code (or your plugin manager) for full coverage."
fi

echo ""
echo "Done. claude-skills installed."
echo ""
echo "Verify with:"
echo "  ls ~/.agents/lib/ ~/.agents/personas/ ~/.claude/skills/ben-pr-*"
echo ""
echo "Re-run this script after every git pull to re-sync."
