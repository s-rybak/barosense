#!/usr/bin/env python3
"""Structural checks on the Mermaid blocks under `docs/`.

    python3 scripts/docs/check_diagrams.py

Mermaid renders in the reader's browser, so a broken diagram passes `mkdocs build` and
shows up as a red error box on the published page. This is not a Mermaid parser — it
catches the failure modes that have actually happened here, using nothing but the standard
library, because the docs toolchain must stay installable from `docs/requirements.txt`
alone:

1. **A participant id that collides with a keyword.** `participant Alt as CMAltimeter`
   parses until the diagram uses `alt`/`else`, at which point the lexer reads the
   participant as the keyword and the whole block fails. This one cost a real debugging
   session.
2. **A diagram with no recognised type on its first line.** Usually a stray blank line
   after the fence.
3. **An unbalanced `subgraph` / `end`**, which silently swallows the rest of the diagram.

For a real grammar check, render the blocks with Mermaid itself; that needs Node and is
deliberately not a dependency of this repository.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

MERMAID_BLOCK = re.compile(r"```mermaid\n(.*?)```", re.DOTALL)

#: Words the Mermaid lexers claim. Matched case-insensitively, which is exactly why
#: `Alt` and `End` are dangerous as identifiers.
KEYWORDS = frozenset(
    """
    alt else opt loop par and rect end note over left right activate deactivate
    critical option break autonumber participant actor link links box
    subgraph direction click class style classdef state
    """.split()
)

DIAGRAM_TYPES = (
    "flowchart", "graph", "sequenceDiagram", "classDiagram", "stateDiagram",
    "stateDiagram-v2", "erDiagram", "journey", "gantt", "pie", "quadrantChart",
    "requirementDiagram", "gitGraph", "mindmap", "timeline", "zenuml", "sankey-beta",
    "xychart-beta", "block-beta", "packet-beta", "architecture-beta", "kanban", "radar",
)

PARTICIPANT = re.compile(r"^\s*(?:participant|actor)\s+([A-Za-z_][\w]*)")


def check_block(body: str) -> list[str]:
    lines = body.splitlines()
    problems: list[str] = []

    first = next((line.strip() for line in lines if line.strip()), "")
    if not first.split()[0].split(":")[0] in {item for item in DIAGRAM_TYPES} and not any(
        first.startswith(item) for item in DIAGRAM_TYPES
    ):
        problems.append(f"перший рядок не називає тип діаграми: {first!r}")

    if first.startswith("sequenceDiagram"):
        for line in lines:
            match = PARTICIPANT.match(line)
            if match and match.group(1).lower() in KEYWORDS:
                problems.append(
                    f"учасник `{match.group(1)}` збігається з ключовим словом Mermaid — "
                    "перейменуйте його"
                )

    opens = sum(1 for line in lines if line.strip().startswith("subgraph"))
    closes = sum(1 for line in lines if line.strip() == "end")
    if first.startswith(("flowchart", "graph")) and opens > closes:
        problems.append(f"`subgraph` без `end`: {opens} відкрито, {closes} закрито")

    return problems


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    docs = root / "docs"

    total = 0
    failures = 0
    for path in sorted(docs.rglob("*.md")):
        text = path.read_text(encoding="utf-8")
        for index, match in enumerate(MERMAID_BLOCK.finditer(text), start=1):
            total += 1
            for problem in check_block(match.group(1)):
                failures += 1
                line = text[: match.start()].count("\n") + 1
                relative = path.relative_to(root)
                print(f"{relative}:{line}: діаграма #{index}: {problem}")

    print(f"check_diagrams: перевірено {total} діаграм, проблем: {failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
