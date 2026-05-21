#!/usr/bin/env bats
#
# Behavior tests for plugins/local/skills/pr-review-engine/scripts/build-changed-lines.sh.
# Run: bats test/test_build_changed_lines.bats
#
# Each test spins up a throwaway git repo in $BATS_TEST_TMPDIR, sets a known
# diff shape, and asserts the JSON output.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$REPO_ROOT/plugins/local/skills/pr-review-engine/scripts/build-changed-lines.sh"
  TMP="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$TMP"
  cd "$TMP"
  git init -q -b main
  git config user.email "test@example.com"
  git config user.name  "Test User"
  git config commit.gpgsign false
}

# Helper: assert a JSON path exists in stdout. Uses python3 (always present
# in macOS + Linux dev environments; the script itself depends on it too).
_jq_has_key() {
  python3 -c "import json, sys; d = json.loads(sys.stdin.read()); sys.exit(0 if '$1' in d else 1)"
}

_jq_lines() {
  python3 -c "import json, sys; d = json.loads(sys.stdin.read()); print(','.join(str(x) for x in d.get('$1', [])))"
}

@test "simple addition hunk → expected line numbers in output" {
  printf 'a\nb\nc\n' > foo.txt
  git add foo.txt
  git commit -q -m "seed"
  BASE=$(git rev-parse HEAD)

  printf 'a\nb\nNEW1\nNEW2\nc\n' > foo.txt
  git add foo.txt
  git commit -q -m "add two lines"

  OUT=$("$SCRIPT" --base "$BASE" --head HEAD)
  echo "$OUT" | _jq_has_key foo.txt
  [ "$(printf '%s' "$OUT" | _jq_lines foo.txt)" = "3,4" ]
}

@test "deletion-only hunk → anchor line present in output (>=1)" {
  printf 'a\nb\nc\nd\ne\n' > foo.txt
  git add foo.txt
  git commit -q -m "seed"
  BASE=$(git rev-parse HEAD)

  # Delete lines b, c, d → leaves a, e. Deletion-only hunk.
  printf 'a\ne\n' > foo.txt
  git add foo.txt
  git commit -q -m "delete middle"

  OUT=$("$SCRIPT" --base "$BASE" --head HEAD)
  # The new file has lines [a, e] → 2 lines. The deletion-only hunk anchors
  # at the new-file line just above the deletion: line 1 ("a"). The clamp
  # in the script ensures line >= 1.
  ANCHOR=$(printf '%s' "$OUT" | _jq_lines foo.txt)
  [ -n "$ANCHOR" ] || { echo "no anchor line for deletion-only hunk; got: $OUT" >&2; return 1; }
  # Specifically: anchor should be 1.
  [ "$ANCHOR" = "1" ] || { echo "expected anchor=1 for deletion-only; got: $ANCHOR" >&2; return 1; }
}

@test "pure rename → file key present with empty array" {
  printf 'unchanged content here\n' > foo.txt
  git add foo.txt
  git commit -q -m "seed"
  BASE=$(git rev-parse HEAD)

  git mv foo.txt bar.txt
  git commit -q -m "rename only"

  OUT=$("$SCRIPT" --base "$BASE" --head HEAD)
  echo "$OUT" | _jq_has_key bar.txt
  # Empty array for pure rename.
  LINES=$(printf '%s' "$OUT" | _jq_lines bar.txt)
  [ -z "$LINES" ] || { echo "expected empty lines for pure rename; got: $LINES" >&2; return 1; }
}

@test "--include-uncommitted unions a staged change" {
  printf 'committed\n' > a.txt
  git add a.txt
  git commit -q -m "seed"
  BASE=$(git rev-parse HEAD)

  printf 'committed\ncommitted-add\n' > a.txt
  git add a.txt
  git commit -q -m "committed change"

  # Now make an uncommitted change to a different file
  printf 'uncommitted-new\n' > b.txt
  git add b.txt   # staged but not committed

  # Without --include-uncommitted: only a.txt visible.
  OUT_PR=$("$SCRIPT" --base "$BASE" --head HEAD)
  echo "$OUT_PR" | _jq_has_key a.txt
  ! echo "$OUT_PR" | _jq_has_key b.txt

  # With --include-uncommitted: both visible.
  OUT_LOCAL=$("$SCRIPT" --base "$BASE" --head HEAD --include-uncommitted)
  echo "$OUT_LOCAL" | _jq_has_key a.txt
  echo "$OUT_LOCAL" | _jq_has_key b.txt
}

@test "single-line hunk (omitted count) parses as one line" {
  printf 'a\nb\nc\n' > foo.txt
  git add foo.txt
  git commit -q -m "seed"
  BASE=$(git rev-parse HEAD)

  printf 'a\nMODIFIED\nc\n' > foo.txt
  git add foo.txt
  git commit -q -m "single-line modify"

  OUT=$("$SCRIPT" --base "$BASE" --head HEAD)
  LINES=$(printf '%s' "$OUT" | _jq_lines foo.txt)
  # The modify is on line 2 of the new file.
  [ "$LINES" = "2" ] || { echo "expected lines=2; got: $LINES" >&2; return 1; }
}

@test "path with spaces survives the rename pipeline" {
  printf 'unchanged\n' > "my notes.md"
  git add "my notes.md"
  git commit -q -m "seed file with space in name"
  BASE=$(git rev-parse HEAD)

  git mv "my notes.md" "my renamed notes.md"
  git commit -q -m "rename"

  OUT=$("$SCRIPT" --base "$BASE" --head HEAD)
  # The NUL-split rename pipeline must preserve the full path with spaces.
  echo "$OUT" | _jq_has_key "my renamed notes.md"
  # And must NOT have shattered it into three tokens.
  ! echo "$OUT" | _jq_has_key my
  ! echo "$OUT" | _jq_has_key renamed
  ! echo "$OUT" | _jq_has_key notes.md
}

@test "multi-rename: two renamed files appear as two distinct keys" {
  # Regression test for the bash-3.2 NUL-stripping bug: command substitution
  # of `git diff -z --name-only --diff-filter=R` strips embedded NULs, so two
  # renames used to collapse into a single garbage key. The fix queries
  # renames from Python subprocess instead (preserves NUL bytes).
  printf 'a\n' > a.txt
  printf 'b\n' > b.txt
  git add a.txt b.txt
  git commit -q -m "seed two files"
  BASE=$(git rev-parse HEAD)

  git mv a.txt renamed1.txt
  git mv b.txt renamed2.txt
  git commit -q -m "two renames"

  OUT=$("$SCRIPT" --base "$BASE" --head HEAD)
  echo "$OUT" | _jq_has_key renamed1.txt
  echo "$OUT" | _jq_has_key renamed2.txt
  # And specifically NOT the concatenated form.
  ! echo "$OUT" | _jq_has_key renamed1.txtrenamed2.txt
}

@test "multi-rename union: committed + uncommitted both surface" {
  printf 'a\n' > a.txt
  printf 'b\n' > b.txt
  git add a.txt b.txt
  git commit -q -m "seed"
  BASE=$(git rev-parse HEAD)

  git mv a.txt renamed-committed.txt
  git commit -q -m "committed rename"

  # Now stage an uncommitted rename of the other file.
  git mv b.txt renamed-staged.txt   # leaves it staged

  OUT=$("$SCRIPT" --base "$BASE" --head HEAD --include-uncommitted)
  echo "$OUT" | _jq_has_key renamed-committed.txt
  echo "$OUT" | _jq_has_key renamed-staged.txt
}

@test "JSON output handles a payload with triple quotes safely" {
  # Triple quotes in file content shouldn't terminate the Python heredoc.
  printf 'literal triple quote: """ in content\n' > t.txt
  git add t.txt
  git commit -q -m "seed"
  BASE=$(git rev-parse HEAD)

  printf 'literal triple quote: """ in content\nadded\n' > t.txt
  git add t.txt
  git commit -q -m "modify"

  # The diff content goes through awk → JSON. The heredoc is single-quoted,
  # so """ in the value can't terminate any Python literal.
  OUT=$("$SCRIPT" --base "$BASE" --head HEAD)
  echo "$OUT" | _jq_has_key t.txt
}
