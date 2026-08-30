"""MkDocs hook: regenerate the API reference before every build.

Registered from `mkdocs.yml` under `hooks:`. It runs on `on_startup`, which fires once per
`mkdocs build` and once per `mkdocs serve` — not on every reload — so a serve session stays
responsive while still starting from freshly parsed source.

The generated pages are written to disk rather than into MkDocs' virtual file system on
purpose: `mkdocs serve` should be able to watch them, and a developer should be able to
open `docs/reference/…` in an editor and read the same Markdown the site renders.
"""

from __future__ import annotations

import logging
import sys
import time
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_ROOT / "scripts" / "docs"))

from swiftdoc.generate import generate  # noqa: E402

log = logging.getLogger("mkdocs.hooks.reference")


def on_startup(command: str, dirty: bool) -> None:
    """Parse the Swift tree and write `docs/reference/` and `docs/generated/`."""
    started = time.time()
    try:
        count, project = generate(_ROOT, _ROOT / "docs")
    except Exception as error:  # noqa: BLE001 — a docs build must say *why* it failed
        log.error("swiftdoc: генерація довідника впала: %s", error)
        raise

    declarations = sum(len(source.declarations) for source in project.files)
    references = sum(len(uses) for uses in project.index.occurrences.values())
    log.info(
        "swiftdoc: %d файлів → %d оголошень, %d звернень, %d таблиць; "
        "%d сторінок за %.1f с",
        len(project.files),
        declarations,
        references,
        len(project.entities),
        count,
        time.time() - started,
    )


def on_serve(server, config, builder):  # noqa: ANN001, ANN201
    """Rebuild the site when a Swift file changes, not only when Markdown does."""
    for target in ("Shared", "Barosense", "BarosenseWatch", "Tests"):
        directory = _ROOT / target
        if directory.is_dir():
            server.watch(str(directory), builder)
    server.watch(str(_ROOT / "scripts" / "docs"), builder)
    return server
