"""Cross-reference index: every place a declared name is mentioned in code.

The point of the whole generator. A hand-written "used by" list rots the moment somebody
adds a call, so this rebuilds it from the source on every docs build.

Matching is by identifier, not by resolved type — there is no Swift type checker here. Two
consequences, both surfaced in the rendered page rather than hidden:

* a name declared once in the repository gets an exact list;
* a name declared several times (`start`, `id`, `body`) gets the union of the call sites of
  all of them, and the page says so and links to every declaration that shares the name.
"""

from __future__ import annotations

import re
from collections import defaultdict

from .model import CALLABLE_KINDS, Declaration, Occurrence, SourceFile
from .parser import strip_noncode

_IDENTIFIER_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")

#: Swift keywords and the handful of stdlib names common enough that indexing them would
#: produce a reference list the length of the codebase without telling anybody anything.
_STOPWORDS = frozenset(
    """
    associatedtype class deinit enum extension fileprivate func import init inout internal
    let open operator private precedencegroup protocol public rethrows static struct
    subscript typealias var actor break case continue default defer do else fallthrough
    for guard if in repeat return throw switch where while as Any catch false is nil
    super self Self throws true try await async some any package consuming borrowing
    get set willSet didSet mutating nonmutating override required convenience lazy weak
    unowned indirect final dynamic optional nonisolated isolated distributed each
    """.split()
)


#: Member names the Swift standard library and SwiftUI also define. A project type that
#: declares one of these gets credited with every `array.count` and every `view.body` in
#: the codebase, because the index matches identifiers rather than resolved types. The
#: per-symbol lists still show them — with a warning — but nothing may *rank* on them.
SHADOWED_MEMBERS = frozenset(
    """
    count isEmpty first last map filter reduce sorted description id body value values
    keys name title text label icon color font size width height min max sum average
    start end date time index offset length range bounds frame padding spacing
    hashValue rawValue allCases init deinit callAsFunction next previous append remove
    insert contains prefix suffix joined split trimmed reversed enumerated indices
    """.split()
)


def _scope_at(declarations: list[Declaration], line: int) -> str:
    """Qualified name of the innermost declaration whose body contains `line`."""
    best: Declaration | None = None
    for declaration in declarations:
        if declaration.line <= line <= declaration.end_line:
            if best is None or declaration.line > best.line:
                best = declaration
    if best is None:
        return ""
    return f"{best.qualified_name}{'()' if best.kind in {'func', 'init'} else ''}"


class ReferenceIndex:
    """Name → occurrences, built once over every parsed file."""

    def __init__(self, files: list[SourceFile], sources: dict[str, str]) -> None:
        self.files = {source.path: source for source in files}
        self.occurrences: dict[str, list[Occurrence]] = defaultdict(list)
        #: name → every declaration that introduces it, anywhere in the repository.
        self.declarations_by_name: dict[str, list[Declaration]] = defaultdict(list)
        #: `(file, line)` pairs that *are* declarations, so they are not counted as uses.
        self._declaration_sites: set[tuple[str, int, str]] = set()

        #: Type name → the source ranges of its body and of every extension on it. Used to
        #: recognise an implicit `self.` access, which carries no `.` to match on.
        self._type_ranges: dict[str, list[tuple[str, int, int]]] = defaultdict(list)

        for source in files:
            for declaration in source.declarations:
                self.declarations_by_name[declaration.name].append(declaration)
                self._declaration_sites.add((source.path, declaration.line, declaration.name))
                if declaration.is_type:
                    self._type_ranges[declaration.name].append(
                        (source.path, declaration.line, declaration.end_line)
                    )

        for source in files:
            self._index_file(source, sources[source.path])

    def _index_file(self, source: SourceFile, text: str) -> None:
        code_lines = strip_noncode(text).splitlines()
        raw_lines = text.splitlines()

        for index, code in enumerate(code_lines):
            line_number = index + 1
            for match in _IDENTIFIER_RE.finditer(code):
                name = match.group(0)
                if name in _STOPWORDS or name not in self.declarations_by_name:
                    continue
                if (source.path, line_number, name) in self._declaration_sites:
                    continue

                tail = code[match.end() :]
                is_call = tail.lstrip().startswith("(")
                head = code[: match.start()].rstrip()
                is_member = head.endswith(".")

                self.occurrences[name].append(
                    Occurrence(
                        name=name,
                        file=source.path,
                        line=line_number,
                        is_call=is_call,
                        is_member_access=is_member,
                        scope=_scope_at(source.declarations, line_number),
                        text=raw_lines[index].strip() if index < len(raw_lines) else "",
                    )
                )

    # ----------------------------------------------------------------------------------

    def is_ambiguous(self, name: str) -> bool:
        """True when several declarations share this identifier."""
        return len(self.owners(name)) > 1

    @staticmethod
    def is_shadowed(name: str) -> bool:
        """True when the standard library defines a member of the same name.

        Such a count is an upper bound and nothing more: `RiskMetrics.count` cannot be
        told apart from `array.count` without a type checker.
        """
        return name in SHADOWED_MEMBERS

    def is_countable(self, declaration: Declaration) -> bool:
        """Whether this declaration's reference count means what it says.

        The gate for any ranking. A count that mixes in a standard-library member or a
        same-named type elsewhere in the project is fine to *show* — the page says so —
        and useless to *sort by*.
        """
        return not self.is_ambiguous(declaration.name) and not self.is_shadowed(declaration.name)

    def owners(self, name: str) -> list[Declaration]:
        """Declarations that introduce `name`, excluding pure `extension` re-openings."""
        return [
            declaration
            for declaration in self.declarations_by_name.get(name, [])
            if declaration.kind != "extension"
        ]

    def references(self, declaration: Declaration, *, include_tests: bool = True) -> list[Occurrence]:
        """Every use of `declaration`, filtered to the shapes that can actually be one.

        The filter is what separates a call-site list from a text search:

        * a method is only *used* where its name is called or reached through a dot, so
          `let delta = …` stops being counted as a use of `PressureTrend.delta(from:)`;
        * an initialiser has no callable name of its own — its uses are the calls that
          spell the owning type, `Pressure(hectopascals:)`;
        * a property is reached through a dot, or bare inside its own type's body, and
          nowhere else.
        """
        if declaration.kind == "init" and declaration.parent:
            owner = declaration.parent.split(".")[-1]
            found = [use for use in self.occurrences.get(owner, []) if use.is_call]
            found = [
                use
                for use in found
                if not self._belongs_to_sibling_initialiser(declaration, owner, use)
            ]
        else:
            found = list(self.occurrences.get(declaration.name, []))

            if declaration.kind in CALLABLE_KINDS:
                found = [use for use in found if use.is_call or use.is_member_access]
            elif declaration.kind in {"var", "let", "case"}:
                ranges = self._type_ranges.get((declaration.parent or "").split(".")[-1], [])
                found = [
                    use
                    for use in found
                    if use.is_member_access or self._within(use, ranges)
                ]

        if not include_tests:
            found = [use for use in found if not use.file.startswith("Tests/")]
        return sorted(found, key=lambda use: (use.file, use.line))

    def _belongs_to_sibling_initialiser(
        self, declaration: Declaration, owner: str, use: Occurrence
    ) -> bool:
        """True when this call is provably a *different* initialiser of the same type.

        `Pressure` has two: `init(hectopascals:)` and `init(kilopascals:)`. Both are matched
        by the same `Pressure(` occurrence, so the first argument label is used to tell them
        apart — but only to *exclude*, never to include. A call whose label sits on the next
        line matches nothing and therefore stays in every list: an extra row a reader can see
        through costs less than a call site silently dropped.
        """
        mine = _first_label(declaration.selector)
        siblings = {
            _first_label(item.selector)
            for item in self.declarations_by_name.get("init", [])
            if item.kind == "init" and (item.parent or "").split(".")[-1] == owner
        }
        siblings.discard(mine)
        if not siblings or not mine:
            return False

        match = re.search(re.escape(owner) + r"\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*:", use.text)
        if not match:
            return False
        return match.group(1) in siblings and match.group(1) != mine

    @staticmethod
    def _within(use: Occurrence, ranges: list[tuple[str, int, int]]) -> bool:
        return any(
            use.file == path and start <= use.line <= end for path, start, end in ranges
        )

    def usage_count(self, declaration: Declaration) -> int:
        return len(self.references(declaration))

    def file_dependencies(self, source: SourceFile) -> list[str]:
        """Other project files whose declarations this one names.

        The outgoing half of the module graph. Built from the same occurrence data, so it
        cannot disagree with the per-symbol lists.
        """
        own = {declaration.name for declaration in source.declarations}
        targets: set[str] = set()
        for name, uses in self.occurrences.items():
            if name in own:
                continue
            if not any(use.file == source.path for use in uses):
                continue
            for declaration in self.declarations_by_name.get(name, []):
                # `extension Foo` re-opens a type; it does not introduce it. Counting it as
                # a declaration site would make the file that *defines* `PressureSeries`
                # look like it depends on the preview extension in a SwiftUI screen.
                if declaration.kind == "extension":
                    continue
                if declaration.file != source.path and declaration.is_type:
                    targets.add(declaration.file)
        return sorted(targets)

    def file_dependents(self, source: SourceFile) -> list[str]:
        """Other project files that name a type declared in this one — the incoming half."""
        own_types = {
            declaration.name
            for declaration in source.declarations
            if declaration.is_type and declaration.kind != "extension"
        }
        callers: set[str] = set()
        for name in own_types:
            for use in self.occurrences.get(name, []):
                if use.file != source.path:
                    callers.add(use.file)
        return sorted(callers)


def _first_label(selector: str) -> str:
    """`init(hectopascals:)` → `hectopascals`; `init()` and `init(_:)` → empty."""
    if "(" not in selector:
        return ""
    inner = selector.split("(", 1)[1].rstrip(")")
    first = inner.split(":", 1)[0]
    return "" if first in {"", "_"} else first
