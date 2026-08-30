#!/usr/bin/env python3
"""Regenerate the API reference, the database schema and the structure pages.

    python3 scripts/docs/generate_reference.py

Writes into `docs/reference/` and `docs/generated/`, both of which are wiped first and
neither of which is committed. The MkDocs hook runs the same code on every build, so this
CLI exists for two cases: checking the output without starting a server, and running the
generator from CI as a guard.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from swiftdoc.generate import generate  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
        help="Repository root (default: inferred from this file's location).",
    )
    parser.add_argument("--docs", type=Path, default=None, help="Docs directory (default: <root>/docs).")
    arguments = parser.parse_args()

    root: Path = arguments.root
    docs_root: Path = arguments.docs or root / "docs"

    started = time.time()
    count, project = generate(root, docs_root)
    elapsed = time.time() - started

    references = sum(len(uses) for uses in project.index.occurrences.values())
    declarations = sum(len(source.declarations) for source in project.files)
    print(
        f"swiftdoc: {len(project.files)} файлів → {declarations} оголошень, "
        f"{references} звернень, {len(project.entities)} таблиць; "
        f"{count} сторінок за {elapsed:.1f} с"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
