"""SwiftData schema extraction — the database chapter, built from the source of truth.

SwiftData has no `.xcdatamodeld` to read: the schema *is* the `@Model` classes plus the
`Schema([...])` lists that name which of them a given store file holds. Both are recovered
here so the ER diagram and the column tables cannot drift from the code the way a
hand-drawn diagram does.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from .model import Declaration, SourceFile

_SCHEMA_RE = re.compile(r"Schema\(\s*\[(.*?)\]\s*\)", re.DOTALL)
_MEMBER_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*self")
_STORE_FILE_RE = re.compile(r'storeFileName\s*=\s*"([^"]+)"')
_RELATIONSHIP_RE = re.compile(r"@Relationship\(([^)]*)\)")

#: Swift types that map onto a SQLite column directly rather than to another entity.
_SCALARS = {
    "Bool", "Int", "Int8", "Int16", "Int32", "Int64", "Double", "Float", "String",
    "Date", "UUID", "Data", "URL", "Decimal",
}


@dataclass
class Column:
    """One persisted property of a `@Model` class."""

    name: str
    swift_type: str
    doc: str
    attributes: list[str]
    line: int
    file: str

    @property
    def is_optional(self) -> bool:
        return self.swift_type.endswith("?")

    @property
    def is_array(self) -> bool:
        return self.swift_type.startswith("[")

    @property
    def base_type(self) -> str:
        text = self.swift_type.rstrip("?")
        if text.startswith("[") and text.endswith("]"):
            text = text[1:-1]
        return text.rstrip("?").strip()

    @property
    def is_unique(self) -> bool:
        return any(".unique" in item for item in self.attributes)

    @property
    def is_external_storage(self) -> bool:
        return any(".externalStorage" in item for item in self.attributes)

    @property
    def is_scalar(self) -> bool:
        return self.base_type in _SCALARS

    @property
    def mermaid_type(self) -> str:
        """Mermaid ER attributes reject `[`, `?` and spaces, so the type is flattened."""
        text = self.base_type or "value"
        if self.is_array:
            text += "_array"
        if self.is_optional:
            text += "_opt"
        return re.sub(r"[^A-Za-z0-9_]", "_", text)


@dataclass
class Entity:
    """A `@Model` class — one SQLite table in the SwiftData store."""

    name: str
    file: str
    line: int
    doc: str
    columns: list[Column] = field(default_factory=list)
    #: Struct types stored inline as codable values rather than as their own table.
    embedded: list[str] = field(default_factory=list)

    @property
    def primary_key(self) -> Column | None:
        for column in self.columns:
            if column.is_unique:
                return column
        return None


@dataclass
class Container:
    """One on-disk store file and the entities its schema lists."""

    owner: str
    file: str
    store_file: str
    entities: list[str]
    doc: str = ""


def _enclosing_type(source: SourceFile, line: int) -> str:
    best: Declaration | None = None
    for declaration in source.declarations:
        if declaration.is_type and declaration.line <= line <= declaration.end_line:
            if best is None or declaration.line > best.line:
                best = declaration
    return best.name if best else ""


def extract_entities(files: list[SourceFile]) -> list[Entity]:
    """Every `@Model` class in the project, with its persisted properties."""
    entities: list[Entity] = []
    for source in files:
        for declaration in source.declarations:
            if "@Model" not in declaration.attributes:
                continue
            entity = Entity(
                name=declaration.name,
                file=source.path,
                line=declaration.line,
                doc=declaration.doc,
            )
            for member in source.declarations:
                if member.parent != declaration.name or member.kind not in {"var", "let"}:
                    continue
                if not member.type_annotation:
                    # A computed bridge such as `var checkIn: CheckIn? { … }` with no written
                    # type, or a property whose type is inferred. Neither is a column.
                    continue
                if member.end_line > member.line:
                    # A body means a computed property — the bridge that maps the row onto
                    # its domain value type (`var checkIn: CheckIn? { … }`). It is API, and
                    # it is documented on the file page, but it is not a column.
                    continue
                entity.columns.append(
                    Column(
                        name=member.name,
                        swift_type=member.type_annotation.split("=")[0].strip(),
                        doc=member.doc,
                        attributes=member.attributes,
                        line=member.line,
                        file=source.path,
                    )
                )
            entity.embedded = sorted(
                {
                    column.base_type
                    for column in entity.columns
                    if not column.is_scalar
                }
            )
            entities.append(entity)
    return entities


def extract_containers(files: list[SourceFile], sources: dict[str, str]) -> list[Container]:
    """Pair every `Schema([...])` with the store file name declared alongside it."""
    containers: list[Container] = []
    for source in files:
        text = sources[source.path]
        for match in _SCHEMA_RE.finditer(text):
            line = text[: match.start()].count("\n") + 1
            owner = _enclosing_type(source, line)
            members = _MEMBER_RE.findall(match.group(1))
            if not members:
                continue

            # The store file name is a sibling declaration in the same type. Falling back
            # to "in-memory" is correct rather than lazy: a schema with no file name in
            # scope belongs to `makeInMemory()`.
            store_file = "(in-memory)"
            for candidate in _STORE_FILE_RE.finditer(text):
                candidate_line = text[: candidate.start()].count("\n") + 1
                if _enclosing_type(source, candidate_line) == owner:
                    store_file = candidate.group(1)
                    break

            existing = next(
                (item for item in containers if item.owner == owner and item.store_file == store_file),
                None,
            )
            if existing:
                existing.entities = sorted(set(existing.entities) | set(members))
                continue

            doc = ""
            for declaration in source.declarations:
                if declaration.name == owner and declaration.is_type:
                    doc = declaration.doc
                    break

            containers.append(
                Container(
                    owner=owner,
                    file=source.path,
                    store_file=store_file,
                    entities=sorted(set(members)),
                    doc=doc,
                )
            )
    return [item for item in containers if item.store_file != "(in-memory)"]
