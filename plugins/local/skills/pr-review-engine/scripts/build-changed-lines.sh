#!/usr/bin/env bash
# build-changed-lines.sh — produce a JSON map { "<path>": [<lines>] } from
# `git diff --unified=0` hunk headers. Used by pr-review-engine Step 3.
#
# Rules: see references/changed-lines.md.
#
# Usage:
#   build-changed-lines.sh --base <merge-base> --head <ref>
#   build-changed-lines.sh --base <merge-base> --head <ref> --include-uncommitted
#
# Output: compact JSON to stdout.

set -euo pipefail

BASE=""
HEAD=""
INCLUDE_UNCOMMITTED=0

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="$2"; shift 2;;
    --head) HEAD="$2"; shift 2;;
    --include-uncommitted) INCLUDE_UNCOMMITTED=1; shift;;
    *) echo "build-changed-lines.sh: unknown argument: $1" >&2; exit 2;;
  esac
done

if [ -z "$BASE" ] || [ -z "$HEAD" ]; then
  echo "build-changed-lines.sh: --base and --head are required" >&2
  exit 2
fi

# AWK that consumes unified=0 diff output and emits {path: [lines]} JSON.
# Handles deletion-only hunks (NEW_COUNT==0 → anchor at NEW) and pure renames
# (no hunks → empty set, but path still appears as a key via --name-only).
parse_diff() {
  awk '
    BEGIN {
      file = ""
      delete files
    }
    /^diff --git/ {
      # Reset on each file header; the path is set when we see +++ b/...
    }
    /^\+\+\+ / {
      # Extract path. Strip the "b/" prefix that git adds for new file paths,
      # or "/dev/null" for deletions.
      sub(/^\+\+\+ /, "")
      if ($0 == "/dev/null") { file = ""; next }
      sub(/^b\//, "")
      file = $0
      if (!(file in files)) files[file] = ""
      next
    }
    /^@@ / {
      if (file == "") next
      # Match "@@ -OLD,OLD_COUNT +NEW,NEW_COUNT @@" — counts default to 1 when omitted.
      n = split($0, parts, " ")
      newpart = ""
      for (i = 1; i <= n; i++) {
        if (parts[i] ~ /^\+/) { newpart = parts[i]; break }
      }
      sub(/^\+/, "", newpart)
      m = split(newpart, np, ",")
      new_start = np[1] + 0
      new_count = (m >= 2) ? (np[2] + 0) : 1

      if (new_count == 0) {
        # Deletion-only hunk: anchor at the new-file line just above the deletion.
        # `new_start` here points one line before the removed block in the new file.
        line = new_start
        if (line < 1) line = 1
        if (files[file] == "") files[file] = line; else files[file] = files[file] "," line
      } else {
        for (j = 0; j < new_count; j++) {
          line = new_start + j
          if (files[file] == "") files[file] = line; else files[file] = files[file] "," line
        }
      }
    }
    END {
      printf "{"
      first = 1
      for (f in files) {
        if (!first) printf ","
        first = 0
        printf "%s:[%s]", quote(f), files[f]
      }
      printf "}\n"
    }
    function quote(s,    out, i, c) {
      out = "\""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\" || c == "\"") out = out "\\" c
        else out = out c
      }
      return out "\""
    }
  '
}

# Build from the committed range first.
COMMITTED_LINES=$(git diff --unified=0 "$BASE..$HEAD" | parse_diff)

# Also union renames: pure renames produce no hunks, so they're invisible to
# the AWK above. Force a key (with an empty array) for renamed files so they
# remain in scope for the file-level filter in Step 6.
RENAMED_FILES=$(git diff --name-only --diff-filter=R "$BASE..$HEAD" 2>/dev/null || true)

# Optionally union uncommitted work.
if [ "$INCLUDE_UNCOMMITTED" -eq 1 ]; then
  UNCOMMITTED_LINES=$(git diff --unified=0 HEAD | parse_diff)
  RENAMED_UNCOMMITTED=$(git diff --name-only --diff-filter=R HEAD 2>/dev/null || true)
else
  UNCOMMITTED_LINES="{}"
  RENAMED_UNCOMMITTED=""
fi

# Merge the two JSON maps + the rename lists via python (the only deterministic
# JSON tool we can assume present on developer machines via PATH).
python3 - <<PY
import json, sys

committed = json.loads('''$COMMITTED_LINES''')
uncommitted = json.loads('''$UNCOMMITTED_LINES''')
renamed = """$RENAMED_FILES""".split() + """$RENAMED_UNCOMMITTED""".split()

merged = {}
for src in (committed, uncommitted):
    for path, lines in src.items():
        if path not in merged:
            merged[path] = set()
        merged[path].update(lines)

# Pure renames: key present with empty list.
for path in renamed:
    merged.setdefault(path, set())

out = {path: sorted(lines) for path, lines in merged.items()}
json.dump(out, sys.stdout, separators=(",", ":"))
sys.stdout.write("\n")
PY
