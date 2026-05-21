#!/usr/bin/env python3
"""validate-findings.py — apply the engine's deterministic finding filters.

Implements:

- WHAT/FIX schema check (Step 5 contract).
- Line-level scope filter with ±15 tolerance (see references/calibration.md).
- Markdown documentation-example filter (see references/scope-filter.md).

Input: JSON array of findings on stdin (or --findings path) + path to the
changed-lines JSON map (--changed-lines).

Output (stdout): JSON object
    {
      "kept":    [<finding>, ...],
      "dropped": [{"finding": <finding>, "drop_reason": "...",
                   "distance_to_nearest_changed_line": <int|null>}, ...],
      "counts":  {"out_of_scope": N, "pre_existing": N, "doc_example": N,
                  "schema": N},
      "failed":  [<finding>, ...]   # schema-fail findings — partial-failure path
    }

Exit code: 0 always (caller inspects the JSON).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

LINE_TOLERANCE = 15  # see references/calibration.md

FP_PATTERNS = re.compile(
    r"(?:secret|api\s*key|token|password|_authtoken|eval\(|"
    r"dangerouslysetinnerhtml|private\s*key|mnemonic)",
    re.IGNORECASE,
)

FENCE_RE = re.compile(r"^\s*(?:```|~~~)")


def _is_inside_fence(file_path: Path, line: int) -> bool:
    """Return True iff `line` (1-based) is inside a fenced code block.

    Walks lines 1..(line-1) — a finding cited ON a fence line itself is
    treated as outside the block, per the scope-filter contract.
    """
    if not file_path.is_file():
        return False
    try:
        text = file_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False
    lines = text.splitlines()
    fence_count = 0
    for raw in lines[: max(line - 1, 0)]:
        if FENCE_RE.match(raw):
            fence_count += 1
    return fence_count % 2 == 1


def _schema_ok(finding: dict) -> bool:
    if not isinstance(finding, dict):
        return False
    if finding.get("severity") not in {"critical", "high", "medium", "low"}:
        return False
    file = finding.get("file")
    if not isinstance(file, str) or not file:
        return False
    line = finding.get("line")
    if not isinstance(line, int) or line <= 0:
        return False
    desc = finding.get("description")
    if not isinstance(desc, str) or not desc:
        return False
    if "WHAT:" not in desc or "FIX:" not in desc:
        return False
    return True


def _distance_to_nearest(line: int, changed_lines: list[int]) -> int | None:
    if not changed_lines:
        return None
    return min(abs(line - cl) for cl in changed_lines)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--findings", type=Path,
                   help="Path to a JSON array of findings. Reads stdin if omitted.")
    p.add_argument("--changed-lines", type=Path, required=True,
                   help="Path to the changed-lines JSON map built by build-changed-lines.sh.")
    p.add_argument("--repo-root", type=Path, default=Path.cwd(),
                   help="Repo root for resolving file paths (default: CWD).")
    p.add_argument("--schema-only", action="store_true",
                   help="Only run the WHAT/FIX schema check; skip scope filters.")
    p.add_argument("--line-tolerance", type=int, default=LINE_TOLERANCE)
    args = p.parse_args()

    try:
        findings_src = args.findings.read_text() if args.findings else sys.stdin.read()
    except OSError as e:
        print(json.dumps({"error": f"cannot read findings file: {e}"}))
        return 0
    try:
        findings = json.loads(findings_src)
    except json.JSONDecodeError as e:
        print(json.dumps({"error": f"invalid findings JSON: {e}"}))
        return 0
    if not isinstance(findings, list):
        print(json.dumps({"error": "findings must be a JSON array"}))
        return 0

    try:
        changed_lines_map = json.loads(args.changed_lines.read_text())
    except OSError as e:
        print(json.dumps({"error": f"cannot read changed-lines file: {e}"}))
        return 0
    except json.JSONDecodeError as e:
        print(json.dumps({"error": f"invalid changed-lines JSON: {e}"}))
        return 0
    if not isinstance(changed_lines_map, dict):
        print(json.dumps({"error": "changed-lines must be a JSON object"}))
        return 0

    kept: list[dict] = []
    dropped: list[dict] = []
    failed: list[dict] = []
    counts = {"out_of_scope": 0, "pre_existing": 0, "doc_example": 0, "schema": 0}

    for f in findings:
        if not _schema_ok(f):
            failed.append(f)
            counts["schema"] += 1
            continue

        if args.schema_only:
            kept.append(f)
            continue

        # Normalize file path: strip leading "./", strip "a/" or "b/" diff prefixes,
        # strip repo-root absolute prefix.
        raw = f["file"]
        norm = raw
        if norm.startswith("./"):
            norm = norm[2:]
        if norm.startswith(("a/", "b/")):
            norm = norm[2:]
        try:
            absroot = args.repo_root.resolve()
            absnorm = Path(norm)
            if absnorm.is_absolute():
                try:
                    norm = str(absnorm.relative_to(absroot))
                except ValueError:
                    pass
        except OSError:
            pass

        if norm not in changed_lines_map:
            dropped.append({
                "finding": f,
                "drop_reason": "file-out-of-scope",
                "distance_to_nearest_changed_line": None,
            })
            counts["out_of_scope"] += 1
            continue

        changed = changed_lines_map[norm]
        # Short-circuit: empty set (pure rename) → keep regardless of line.
        if not changed:
            kept.append(f)
            continue

        line = f["line"]
        if line in changed:
            keep_due_to_line = True
            dist = 0
        else:
            dist = _distance_to_nearest(line, changed)
            keep_due_to_line = dist is not None and dist <= args.line_tolerance

        if not keep_due_to_line:
            dropped.append({
                "finding": f,
                "drop_reason": "line-pre-existing",
                "distance_to_nearest_changed_line": dist,
            })
            counts["pre_existing"] += 1
            continue

        # Markdown documentation-example filter.
        if norm.endswith(".md") and FP_PATTERNS.search(f["description"]):
            file_abs = args.repo_root / norm
            if _is_inside_fence(file_abs, line):
                dropped.append({
                    "finding": f,
                    "drop_reason": "doc-example-fp",
                    "distance_to_nearest_changed_line": dist,
                })
                counts["doc_example"] += 1
                continue

        kept.append(f)

    out = {"kept": kept, "dropped": dropped, "counts": counts, "failed": failed}
    print(json.dumps(out, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
