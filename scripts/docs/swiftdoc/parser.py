"""A line-oriented Swift reader: source text in, `Declaration` records out.

This is not a Swift parser and does not pretend to be one. It recovers declarations,
their doc comments and their nesting by tracking brace depth over comment- and
string-stripped text. That is enough for a reference site and it has one large advantage
over the real thing: it needs no toolchain, so the docs build on a Linux CI runner that
has never seen Xcode.

What it deliberately does not do: resolve types. A method reference is matched by
identifier, so two same-named methods on different types share a reference list. The
renderer says so where it happens rather than pretending the match is exact — see
`xref.ReferenceIndex.ambiguous_names`.
"""

from __future__ import annotations

import re

from .model import Declaration, SourceFile

# --------------------------------------------------------------------------------------
# Comment / string stripping
# --------------------------------------------------------------------------------------

_RAW_STRING_OPEN = re.compile(r'#+"')


def strip_noncode(source: str) -> str:
    """Blank out comments and string literals, preserving length and line breaks.

    Every consumer downstream indexes by line number into the *original* text, so the
    result has to stay character-for-character aligned: replaced spans become spaces and
    newlines survive untouched.
    """
    out = list(source)
    i = 0
    n = len(source)
    # Swift block comments nest, so this is a counter rather than a flag.
    block_depth = 0

    def blank(start: int, stop: int) -> None:
        for k in range(start, min(stop, n)):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        ch = source[i]

        if block_depth:
            if source.startswith("/*", i):
                block_depth += 1
                blank(i, i + 2)
                i += 2
                continue
            if source.startswith("*/", i):
                block_depth -= 1
                blank(i, i + 2)
                i += 2
                continue
            blank(i, i + 1)
            i += 1
            continue

        if source.startswith("//", i):
            end = source.find("\n", i)
            end = n if end == -1 else end
            blank(i, end)
            i = end
            continue

        if source.startswith("/*", i):
            block_depth = 1
            blank(i, i + 2)
            i += 2
            continue

        if source.startswith('"""', i):
            end = source.find('"""', i + 3)
            end = n if end == -1 else end + 3
            blank(i, end)
            i = end
            continue

        raw = _RAW_STRING_OPEN.match(source, i)
        if raw:
            hashes = raw.group(0)[:-1]
            terminator = '"' + hashes
            end = source.find(terminator, raw.end())
            end = n if end == -1 else end + len(terminator)
            blank(i, end)
            i = end
            continue

        if ch == '"':
            j = i + 1
            while j < n and source[j] != '"':
                if source[j] == "\\":
                    j += 1
                if source[j : j + 1] == "\n":
                    break
                j += 1
            blank(i, j + 1)
            i = j + 1
            continue

        i += 1

    return "".join(out)


# --------------------------------------------------------------------------------------
# Declaration patterns
# --------------------------------------------------------------------------------------

_MODIFIERS = (
    "public|private|fileprivate|internal|open|package|final|static|class|override|"
    "mutating|nonmutating|convenience|required|lazy|weak|unowned|indirect|dynamic|"
    "optional|nonisolated|isolated|consuming|borrowing|distributed|async|throws"
)

#: Attributes written on the same line as the declaration — `@Attribute(.unique) var id`.
#: Without this prefix every SwiftData column would be invisible to the reader.
_INLINE_ATTRS = r"(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^()]*\))?\s+)*"

#: Access-control modifiers can also carry a scope — `private(set) var`.
_PREFIX = _INLINE_ATTRS + r"(?:(?:" + _MODIFIERS + r")(?:\([a-z]+\))?\s+)*"

_TYPE_RE = re.compile(
    r"^\s*" + _PREFIX + r"\b(struct|class|enum|actor|protocol|extension)\s+"
    r"([A-Za-z_][A-Za-z0-9_]*)"
)

_FUNC_RE = re.compile(
    r"^\s*" + _PREFIX + r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*|[-+*/%<>=!&|^~?]+)"
)

_INIT_RE = re.compile(r"^\s*" + _PREFIX + r"\binit\b[?!]?\s*[(<]")

_SUBSCRIPT_RE = re.compile(r"^\s*" + _PREFIX + r"\bsubscript\s*[(<]")

_VAR_RE = re.compile(
    r"^\s*" + _PREFIX + r"\b(var|let)\s+([A-Za-z_][A-Za-z0-9_]*)"
)

_CASE_RE = re.compile(r"^\s*case\s+([A-Za-z_][A-Za-z0-9_]*)")

_ALIAS_RE = re.compile(
    r"^\s*" + _PREFIX + r"\b(typealias|associatedtype)\s+([A-Za-z_][A-Za-z0-9_]*)"
)

_ATTRIBUTE_RE = re.compile(r"^\s*(@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?)\s*$")
_INLINE_ATTRIBUTE_RE = re.compile(r"@[A-Za-z_][A-Za-z0-9_]*(?:\([^()]*\))?")
_IMPORT_RE = re.compile(r"^\s*(?:@\w+\s+)?import\s+(?:struct|class|enum|func|var|let|protocol|typealias)?\s*([A-Za-z0-9_.]+)")
_MODIFIER_WORD_RE = re.compile(r"\b(" + _MODIFIERS + r")\b")

#: Declaration kinds whose bodies hold locals rather than members.
_LOCAL_SCOPES = frozenset({"func", "init", "subscript", "var", "let"})


def _selector(signature: str, name: str) -> str:
    """Turn `func delta(from earlier: Pressure) -> Double` into `delta(from:)`.

    Falls back to `name` whenever the parameter list cannot be read cleanly — a wrong
    selector is worse than a plain name, because it looks authoritative.
    """
    open_paren = signature.find("(", signature.find(name) + len(name))
    if open_paren == -1:
        return name

    depth = 0
    close = -1
    for idx in range(open_paren, len(signature)):
        char = signature[idx]
        if char in "([<":
            depth += 1
        elif char in ")]>":
            depth -= 1
            if depth == 0 and char == ")":
                close = idx
                break
    if close == -1:
        return name

    inner = signature[open_paren + 1 : close].strip()
    if not inner:
        return f"{name}()"

    labels: list[str] = []
    depth = 0
    current = ""
    for char in inner:
        if char in "([<{":
            depth += 1
        elif char in ")]>}":
            depth -= 1
        if char == "," and depth == 0:
            labels.append(current)
            current = ""
        else:
            current += char
    labels.append(current)

    parts: list[str] = []
    for label in labels:
        head = label.split(":", 1)[0].strip()
        words = head.split()
        parts.append("_:" if not words else f"{words[0]}:")
    return f"{name}({''.join(parts)})"


def _type_annotation(signature: str, name: str) -> str:
    """The written type of a property, when the source spells one out."""
    match = re.search(re.escape(name) + r"\s*:\s*([^={]+)", signature)
    if not match:
        return ""
    return match.group(1).strip().rstrip(",")


def _conformances(signature: str, name: str) -> list[str]:
    after = signature.split(name, 1)[-1]
    if ":" not in after:
        return []
    tail = after.split(":", 1)[1]
    tail = tail.split("where")[0].split("{")[0]
    out: list[str] = []
    depth = 0
    current = ""
    for char in tail:
        if char in "<([":
            depth += 1
        elif char in ">)]":
            depth -= 1
        if char == "," and depth == 0:
            out.append(current.strip())
            current = ""
        else:
            current += char
    if current.strip():
        out.append(current.strip())
    return [item for item in out if item]


def _collect_signature(lines: list[str], start: int) -> tuple[str, int]:
    """Join a declaration that wraps across lines into one string.

    Stops at the body brace, at a balanced parameter list, or after eight lines — the
    guard is there because an unbalanced paren in a file the reader mis-scanned would
    otherwise swallow the rest of the file into one signature.
    """
    text = ""
    depth = 0
    last = start
    for offset in range(0, 8):
        index = start + offset
        if index >= len(lines):
            break
        line = lines[index]
        last = index
        for char in line:
            if char in "([<":
                depth += 1
            elif char in ")]>":
                depth = max(0, depth - 1)
            elif char == "{" and depth == 0:
                text += " "
                return re.sub(r"\s+", " ", text).strip(), last
            text += char
        text += " "
        if depth == 0 and offset > 0:
            break
        if depth == 0 and ("(" in line or "=" in line or offset == 0):
            break
    return re.sub(r"\s+", " ", text).strip(), last


def _doc_above(raw_lines: list[str], index: int) -> tuple[str, list[str]]:
    """Read the `///` block and `@attribute` lines immediately above a declaration.

    Returns the doc comment as markdown (leading `///` stripped) and the attributes, in
    source order. Blank lines end the block: a comment separated from the declaration by
    an empty line is a section note, not that declaration's documentation.
    """
    doc: list[str] = []
    attributes: list[str] = []
    cursor = index - 1

    while cursor >= 0:
        line = raw_lines[cursor].strip()
        if not line:
            break
        attribute = _ATTRIBUTE_RE.match(raw_lines[cursor])
        if attribute:
            attributes.insert(0, attribute.group(1))
            cursor -= 1
            continue
        if line.startswith("///"):
            doc.insert(0, line[3:].removeprefix(" "))
            cursor -= 1
            continue
        if line.startswith("//"):
            # A plain `//` note is an implementation aside, not API documentation. It is
            # skipped rather than rendered — but it still ends the block, because a `///`
            # above it documents whatever that note is attached to.
            break
        break

    return "\n".join(doc).strip(), attributes


def _file_doc(raw_lines: list[str]) -> str:
    """The `///` block at the very top of a file, before any import or declaration."""
    doc: list[str] = []
    for line in raw_lines:
        stripped = line.strip()
        if not stripped:
            if doc:
                break
            continue
        if stripped.startswith("///"):
            doc.append(stripped[3:].removeprefix(" "))
            continue
        break
    return "\n".join(doc).strip()


def parse_file(path: str, target: str, source: str) -> SourceFile:
    """Parse one Swift file into a `SourceFile`."""
    raw_lines = source.splitlines()
    code_lines = strip_noncode(source).splitlines()
    # `splitlines` on the stripped copy can come back one short when the file ends without
    # a newline inside a comment; pad so the two views stay index-aligned.
    while len(code_lines) < len(raw_lines):
        code_lines.append("")

    declarations: list[Declaration] = []
    imports: list[str] = []
    # (declaration, brace depth of its body)
    stack: list[tuple[Declaration, int]] = []
    depth = 0
    skip_until = -1

    for index, code in enumerate(code_lines):
        line_number = index + 1
        depth_before = depth

        for char in code:
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1

        while stack and stack[-1][1] > depth_before:
            stack.pop()

        if index <= skip_until:
            continue

        imported = _IMPORT_RE.match(code)
        if imported:
            imports.append(imported.group(1))
            continue

        kind = None
        name = None

        type_match = _TYPE_RE.match(code)
        func_match = _FUNC_RE.match(code)
        var_match = _VAR_RE.match(code)
        alias_match = _ALIAS_RE.match(code)

        if type_match:
            kind, name = type_match.group(1), type_match.group(2)
        elif func_match:
            kind, name = "func", func_match.group(1)
        elif _INIT_RE.match(code):
            kind, name = "init", "init"
        elif _SUBSCRIPT_RE.match(code):
            kind, name = "subscript", "subscript"
        elif alias_match:
            kind, name = alias_match.group(1), alias_match.group(2)
        elif var_match:
            kind, name = var_match.group(1), var_match.group(2)
        elif _CASE_RE.match(code) and stack and stack[-1][0].kind == "enum":
            kind, name = "case", _CASE_RE.match(code).group(1)

        if not kind or not name:
            continue

        signature, last_line = _collect_signature(code_lines, index)
        skip_until = last_line
        doc, attributes = _doc_above(raw_lines, index)
        attributes += _INLINE_ATTRIBUTE_RE.findall(code.split(kind)[0] if kind in {"var", "let"} else "")
        modifiers = _MODIFIER_WORD_RE.findall(signature.split("(")[0])

        # A `let` inside a method body is a local, not API. Anything nested in a callable
        # or in a computed property's accessor is dropped rather than published — without
        # this the reference index fills with `let id = checkIn.id` noise that shares its
        # name with a real property and poisons that property's call-site list.
        if any(owner.kind in _LOCAL_SCOPES for owner, _ in stack):
            continue

        parent = None
        for owner, _ in reversed(stack):
            if owner.is_type:
                parent = owner.qualified_name if owner.kind != "extension" else owner.name
                break

        declaration = Declaration(
            kind=kind,
            name=name,
            signature=signature,
            file=path,
            line=line_number,
            end_line=last_line + 1,
            depth=depth_before,
            doc=doc,
            attributes=list(dict.fromkeys(attributes)),
            modifiers=list(dict.fromkeys(modifiers)),
            parent=parent,
            selector=_selector(signature, name) if kind in {"func", "init"} else "",
            conformances=_conformances(signature, name) if kind in {"struct", "class", "enum", "actor", "protocol", "extension"} else [],
            type_annotation=_type_annotation(signature, name) if kind in {"var", "let"} else "",
        )
        declarations.append(declaration)

        opens_body = "{" in "".join(code_lines[index : last_line + 1])
        if opens_body:
            stack.append((declaration, depth_before + 1))

    _assign_end_lines(declarations, code_lines)

    return SourceFile(
        path=path,
        target=target,
        imports=sorted(set(imports)),
        doc=_file_doc(raw_lines) or _primary_doc(declarations),
        declarations=declarations,
        line_count=len(raw_lines),
    )


def _primary_doc(declarations: list[Declaration]) -> str:
    """A file with no header comment is described by its first documented type."""
    for declaration in declarations:
        if declaration.is_type and declaration.doc:
            return declaration.doc
    for declaration in declarations:
        if declaration.doc:
            return declaration.doc
    return ""


def _assign_end_lines(declarations: list[Declaration], code_lines: list[str]) -> None:
    """Extend each declaration to the line where its body brace closes.

    `end_line` already covers the signature. A declaration only grows past that when its
    *signature lines* open a brace — otherwise a stored property would swallow the body of
    whatever member follows it.
    """
    for declaration in declarations:
        start = declaration.line - 1
        signature_end = declaration.end_line
        if "{" not in "".join(code_lines[start:signature_end]):
            continue

        depth = 0
        seen_open = False
        for index in range(start, len(code_lines)):
            for char in code_lines[index]:
                if char == "{":
                    depth += 1
                    seen_open = True
                elif char == "}":
                    depth -= 1
            if seen_open and depth <= 0:
                declaration.end_line = index + 1
                break
