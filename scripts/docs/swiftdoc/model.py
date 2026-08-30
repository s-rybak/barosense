"""Data types shared by the Swift parser, the cross-reference index and the renderer.

Deliberately plain dataclasses with no behaviour beyond derived names: the parser is the
only thing that constructs them, and every consumer treats them as read-only records.
"""

from __future__ import annotations

from dataclasses import dataclass, field

#: Declaration kinds that own a namespace — members found inside them are qualified by them.
TYPE_KINDS = frozenset({"struct", "class", "enum", "actor", "protocol", "extension"})

#: Declaration kinds rendered as callable members.
CALLABLE_KINDS = frozenset({"func", "init", "subscript"})

#: Declaration kinds rendered as stored/computed state.
VALUE_KINDS = frozenset({"var", "let", "case", "typealias", "associatedtype"})

#: Human-readable Ukrainian labels, used in headings and index tables.
KIND_LABELS: dict[str, str] = {
    "struct": "структура",
    "class": "клас",
    "enum": "перелік",
    "actor": "актор",
    "protocol": "протокол",
    "extension": "розширення",
    "func": "метод",
    "init": "ініціалізатор",
    "subscript": "індекс",
    "var": "властивість",
    "let": "константа",
    "case": "варіант",
    "typealias": "псевдонім",
    "associatedtype": "асоційований тип",
}

#: Short badge text for the Material "chip" next to a declaration heading.
KIND_BADGES: dict[str, str] = {
    "struct": "struct",
    "class": "class",
    "enum": "enum",
    "actor": "actor",
    "protocol": "protocol",
    "extension": "extension",
    "func": "func",
    "init": "init",
    "subscript": "subscript",
    "var": "var",
    "let": "let",
    "case": "case",
    "typealias": "typealias",
    "associatedtype": "associatedtype",
}


@dataclass
class Declaration:
    """One Swift declaration, as recovered from the source text.

    `qualified_name` is what the cross-reference index keys on for display; `name` is what
    it keys on for matching, because the parser has no type checker and can only match
    identifiers.
    """

    kind: str
    name: str
    signature: str
    file: str
    line: int
    end_line: int
    depth: int
    doc: str = ""
    attributes: list[str] = field(default_factory=list)
    modifiers: list[str] = field(default_factory=list)
    parent: str | None = None
    #: For `func`, the Swift selector form — `delta(from:)`. Empty for everything else.
    selector: str = ""
    #: For `extension`, the conformance list after the colon.
    conformances: list[str] = field(default_factory=list)
    #: For `var`/`let`/`case`, the written type annotation when there is one.
    type_annotation: str = ""

    @property
    def qualified_name(self) -> str:
        return f"{self.parent}.{self.name}" if self.parent else self.name

    @property
    def display_name(self) -> str:
        """What a heading shows: the selector for methods, the bare name otherwise."""
        return self.selector or self.name

    @property
    def access(self) -> str:
        for level in ("open", "public", "package", "internal", "fileprivate", "private"):
            if level in self.modifiers:
                return level
        return "internal"

    @property
    def is_type(self) -> bool:
        return self.kind in TYPE_KINDS

    @property
    def is_test(self) -> bool:
        return self.file.startswith("Tests/")


@dataclass
class Occurrence:
    """One identifier seen in code (never in a comment or a string literal)."""

    name: str
    file: str
    line: int
    #: True when the very next non-space character is `(` — a call or an initialisation.
    is_call: bool
    #: True when the identifier is preceded by `.` — a member access rather than a bare name.
    is_member_access: bool
    #: Qualified name of the declaration whose body this line sits in, when there is one.
    scope: str = ""
    #: The source line, trimmed. Rendered as the reference's excerpt.
    text: str = ""


@dataclass
class SourceFile:
    """A parsed Swift file."""

    path: str
    target: str
    imports: list[str]
    doc: str
    declarations: list[Declaration]
    line_count: int
