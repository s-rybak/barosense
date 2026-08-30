"""Markdown emission for the generated API reference.

Everything under `docs/reference/` comes out of here. Nothing in that directory is written
by hand, and nothing in it is committed — see `docs/reference/index.md`, which this module
also writes, for the note that says so to a reader who arrives at the site.
"""

from __future__ import annotations

import posixpath
import re
from collections import defaultdict
from dataclasses import dataclass

from .model import KIND_BADGES, KIND_LABELS, Declaration, Occurrence, SourceFile
from .xref import ReferenceIndex

#: Blob URL for a source line. Pinned to `main` rather than to the building branch: a
#: reader following a link from the published site wants the shipped line, and a branch
#: name baked into thousands of links breaks the day that branch is deleted.
SOURCE_URL = "https://github.com/s-rybak/barosense/blob/main/{path}#L{line}"

#: Ukrainian names for the three source roots, used in headings and nav.
TARGET_TITLES = {
    "Shared": "Shared — спільне ядро",
    "Barosense": "Barosense — iOS-таргет",
    "BarosenseWatch": "BarosenseWatch — watchOS-таргет",
    "Tests": "Tests — юніт-тести",
}

TARGET_BLURBS = {
    "Shared": (
        "Домен, сервіси, ознаки та ризик-модель. Без UI-фреймворків — це перевіряє "
        "кастомне правило SwiftLint `shared_ui_free`. Усе тут має запускатися зі "
        "звичайного XCTest на синтетичному вході."
    ),
    "Barosense": (
        "SwiftUI-екрани, контролери життєвого циклу, дозволи та платформна обв'язка "
        "iPhone. Логіка, яку можна протестувати, живе не тут, а в `Shared/`."
    ),
    "BarosenseWatch": (
        "Тонкий клієнт. Годинник не читає барометр — він показує знімок, який надіслав "
        "iPhone через `WatchConnectivityPressureLink`."
    ),
    "Tests": (
        "Один тестовий таргет. Фікстури синтетичні: без `HKHealthStore`, без "
        "`CMAltimeter`, без мережі."
    ),
}

_CODE_SPAN_RE = re.compile(r"`[^`]*`")
_SLUG_STRIP_RE = re.compile(r"[^a-z0-9]+")


def slug(text: str) -> str:
    return _SLUG_STRIP_RE.sub("-", text.lower()).strip("-")


def anchor_for(declaration: Declaration) -> str:
    """Stable in-page anchor. Includes the kind so `case x` and `var x` cannot collide."""
    return slug(f"{declaration.kind}-{declaration.qualified_name}-{declaration.line}")


def page_for(path: str) -> str:
    """`Shared/Models/Pressure.swift` → `Shared/Models/Pressure.md`, relative to `reference/`."""
    return path[: -len(".swift")] + ".md" if path.endswith(".swift") else path + ".md"


def escape_markdown(text: str) -> str:
    """Make a Swift doc comment safe to drop into a Markdown page.

    Swift documentation is full of generic parameters — `Set<WellbeingTag.ID>`, `[String]`.
    Inside a code span they are fine; outside one, `<` opens an HTML tag and the rest of
    the paragraph disappears from the rendered page. Code spans are preserved verbatim and
    only the prose between them is escaped.
    """
    out: list[str] = []
    cursor = 0
    for match in _CODE_SPAN_RE.finditer(text):
        out.append(text[cursor : match.start()].replace("<", "&lt;").replace(">", "&gt;"))
        out.append(match.group(0))
        cursor = match.end()
    out.append(text[cursor:].replace("<", "&lt;").replace(">", "&gt;"))
    return "".join(out)


def indent(text: str, spaces: int = 4) -> str:
    pad = " " * spaces
    return "\n".join(pad + line if line.strip() else "" for line in text.splitlines())


@dataclass
class Link:
    """A resolved cross-reference target."""

    page: str
    anchor: str

    def relative_to(self, source_page: str) -> str:
        relative = posixpath.relpath(self.page, posixpath.dirname(source_page))
        return f"{relative}#{self.anchor}" if self.anchor else relative


class Renderer:
    """Turns parsed files plus a reference index into the pages under `docs/reference/`."""

    #: A reference list longer than this is truncated, with the count kept honest and a
    #: link to the full search. Rendering 143 call sites for `Pressure.hectopascals`
    #: buries the documentation under the index.
    MAX_REFERENCES = 40

    def __init__(self, files: list[SourceFile], index: ReferenceIndex) -> None:
        self.files = files
        self.index = index
        self.by_path = {source.path: source for source in files}
        self.declaration_links: dict[tuple[str, int], Link] = {}
        for source in files:
            for declaration in source.declarations:
                self.declaration_links[(declaration.file, declaration.line)] = Link(
                    page_for(declaration.file), anchor_for(declaration)
                )

    # -- helpers -----------------------------------------------------------------------

    def _scope_link(self, use: Occurrence, from_page: str) -> str:
        """A call site links to the *caller*, which is what a reader wants to open next."""
        source = self.by_path.get(use.file)
        target = Link(page_for(use.file), "")
        if source:
            best: Declaration | None = None
            for declaration in source.declarations:
                if declaration.line <= use.line <= declaration.end_line:
                    if best is None or declaration.line > best.line:
                        best = declaration
            if best is not None:
                target = self.declaration_links[(best.file, best.line)]
        return target.relative_to(from_page)

    def _source_link(self, path: str, line: int) -> str:
        return SOURCE_URL.format(path=path, line=line)

    # -- reference block ---------------------------------------------------------------

    def _references_block(self, declaration: Declaration, page: str) -> str:
        uses = self.index.references(declaration)
        if not uses:
            return (
                '!!! info "Використань не знайдено"\n'
                "    Індексатор не знайшов жодного звернення до цього імені поза його "
                "оголошенням. Це або точка входу (виклик із SwiftUI, системи чи "
                "`@main`), або мертвий код.\n"
            )

        header = f'??? quote "Де використовується — {len(uses)}"\n'
        lines = ["", "| Місце | Контекст | Рядок коду |", "| --- | --- | --- |"]

        for use in uses[: self.MAX_REFERENCES]:
            location = f"[`{use.file}:{use.line}`]({self._scope_link(use, page)})"
            scope = f"`{use.scope}`" if use.scope else "—"
            snippet = use.text.replace("|", "\\|").replace("`", "'")
            if len(snippet) > 90:
                snippet = snippet[:87] + "…"
            lines.append(f"| {location} | {scope} | `{snippet}` |")

        if len(uses) > self.MAX_REFERENCES:
            lines.append(
                f"| … | — | *ще {len(uses) - self.MAX_REFERENCES}; повний список — "
                f"через пошук по сайту* |"
            )

        note = ""
        if self.index.is_shadowed(declaration.name):
            note += (
                "\n**Ім'я збігається з членом стандартної бібліотеки.** `"
                + declaration.name
                + "` визначено і в Swift/SwiftUI, а індексатор зіставляє ідентифікатори "
                "без перевірки типів — тож число вище є **верхньою межею**: у нього "
                "потрапляють і звернення до однойменних членів масивів, рядків і в'юшок.\n"
            )
        if self.index.is_ambiguous(declaration.name):
            owners = self.index.owners(declaration.name)
            others = [item for item in owners if item.line != declaration.line or item.file != declaration.file]
            listed = ", ".join(
                f"[`{item.qualified_name}`]({self.declaration_links[(item.file, item.line)].relative_to(page)})"
                for item in others[:6]
            )
            note += (
                "\n**Ім'я неоднозначне.** Індексатор зіставляє за ідентифікатором, без "
                "перевірки типів, тому список вище може містити звернення до однойменних "
                f"символів: {listed}"
                + (" та інших." if len(others) > 6 else ".")
                + "\n"
            )

        return header + indent("\n".join(lines) + "\n" + note) + "\n"

    # -- declaration block -------------------------------------------------------------

    def _declaration_block(self, declaration: Declaration, page: str, level: int) -> str:
        heading = "#" * level
        badge = KIND_BADGES.get(declaration.kind, declaration.kind)
        name = declaration.display_name
        title = declaration.qualified_name if declaration.kind != "extension" else f"extension {declaration.name}"
        display = name if declaration.parent is None else f"{declaration.parent}.{name}"
        if declaration.kind == "extension":
            display = f"extension {declaration.name}"

        out = [
            f"{heading} `{display}` <small>{badge}</small> {{ #{anchor_for(declaration)} }}",
            "",
        ]

        chips = [f"`{declaration.access}`"]
        chips += [f"`{item}`" for item in declaration.attributes]
        chips += [
            f"`{item}`"
            for item in declaration.modifiers
            if item not in {"public", "private", "internal", "fileprivate", "open", "package"}
        ]
        source = self._source_link(declaration.file, declaration.line)
        chips.append(f"[рядок {declaration.line}]({source})")
        out.append(" · ".join(chips))
        out.append("")

        out.append("```swift")
        out.append(declaration.signature)
        out.append("```")
        out.append("")

        if declaration.doc:
            out.append(escape_markdown(declaration.doc))
            out.append("")
        else:
            out.append(
                "*Без doc-коментаря в коді.* Опис береться з `///` — додайте його у файлі, "
                "і він з'явиться тут при наступній генерації."
            )
            out.append("")

        if declaration.conformances:
            listed = ", ".join(f"`{item}`" for item in declaration.conformances)
            out.append(f"**Відповідає:** {listed}")
            out.append("")

        if declaration.type_annotation:
            out.append(f"**Тип:** `{escape_markdown(declaration.type_annotation)}`")
            out.append("")

        out.append(self._references_block(declaration, page))
        out.append("")
        return "\n".join(out)

    # -- pages -------------------------------------------------------------------------

    def file_page(self, source: SourceFile) -> str:
        page = page_for(source.path)
        name = posixpath.basename(source.path)
        out = [
            "---",
            f"title: {name}",
            f"description: {source.path}",
            "---",
            "",
            f"# `{name}`",
            "",
        ]

        meta = [
            f"**Шлях:** `{source.path}`",
            f"**Таргет:** `{source.target}`",
            f"**Рядків:** {source.line_count}",
            f"**Оголошень:** {len(source.declarations)}",
            f"[:material-github: Відкрити на GitHub]({self._source_link(source.path, 1)})",
        ]
        out.append(" · ".join(meta))
        out.append("")

        if source.doc:
            out.append('!!! abstract "Призначення"')
            out.append(indent(escape_markdown(source.doc)))
            out.append("")

        if source.imports:
            listed = " ".join(f"`{item}`" for item in source.imports)
            out.append(f"**Імпорти:** {listed}")
            out.append("")

        if source.declarations:
            out.append("## Що оголошено")
            out.append("")
            out.append("| Символ | Вид | Рядок | Використань |")
            out.append("| --- | --- | --- | --- |")
            for declaration in source.declarations:
                link = f"[`{declaration.qualified_name}`](#{anchor_for(declaration)})"
                label = KIND_LABELS.get(declaration.kind, declaration.kind)
                count = len(self.index.references(declaration))
                out.append(f"| {link} | {label} | {declaration.line} | {count} |")
            out.append("")

        out.append(self._dependency_block(source, page))

        out.append("## Деталі")
        out.append("")
        for declaration in source.declarations:
            level = 3 if declaration.parent is None else min(6, 4 + declaration.qualified_name.count("."))
            out.append(self._declaration_block(declaration, page, level))

        return "\n".join(out)

    def _dependency_block(self, source: SourceFile, page: str) -> str:
        outgoing = self.index.file_dependencies(source)
        incoming = self.index.file_dependents(source)
        if not outgoing and not incoming:
            return ""

        def listed(paths: list[str]) -> str:
            items = []
            for path in paths[:25]:
                target = Link(page_for(path), "").relative_to(page)
                items.append(f"[`{path}`]({target})")
            if len(paths) > 25:
                items.append(f"*…ще {len(paths) - 25}*")
            return ", ".join(items) if items else "—"

        out = ["## Зв'язки файлу", ""]
        out.append('=== "Використовує"')
        out.append("")
        out.append(indent(listed(outgoing)))
        out.append("")
        out.append('=== "Використовується у"')
        out.append("")
        out.append(indent(listed(incoming)))
        out.append("")
        return "\n".join(out)

    # -- indexes -----------------------------------------------------------------------

    def target_index(self, target: str) -> str:
        sources = sorted(
            (item for item in self.files if item.target == target), key=lambda item: item.path
        )
        out = [
            "---",
            f"title: {target}",
            "---",
            "",
            f"# {TARGET_TITLES.get(target, target)}",
            "",
            TARGET_BLURBS.get(target, ""),
            "",
            f"**Файлів:** {len(sources)} · "
            f"**Оголошень:** {sum(len(item.declarations) for item in sources)}",
            "",
        ]

        grouped: dict[str, list[SourceFile]] = defaultdict(list)
        for source in sources:
            folder = posixpath.dirname(source.path)
            grouped[folder].append(source)

        for folder in sorted(grouped):
            out.append(f"## `{folder}/`")
            out.append("")
            out.append("| Файл | Що це | Оголошень | Рядків |")
            out.append("| --- | --- | --- | --- |")
            for source in grouped[folder]:
                page = page_for(source.path)
                relative = posixpath.relpath(page, target)
                summary = _first_sentence(source.doc) or "—"
                name = posixpath.basename(source.path)
                out.append(
                    f"| [`{name}`]({relative}) | {escape_markdown(summary)} "
                    f"| {len(source.declarations)} | {source.line_count} |"
                )
            out.append("")

        return "\n".join(out)

    def types_index(self) -> str:
        types = [
            declaration
            for source in self.files
            for declaration in source.declarations
            if declaration.is_type and declaration.kind != "extension"
        ]
        types.sort(key=lambda item: item.name.lower())

        out = [
            "---",
            "title: Покажчик типів",
            "search:",
            "  exclude: true",
            "---",
            "",
            "# Покажчик типів",
            "",
            f"Усі {len(types)} типів проєкту — структури, класи, переліки, актори й "
            "протоколи — з місцем оголошення та кількістю знайдених звернень.",
            "",
            "| Тип | Вид | Файл | Використань |",
            "| --- | --- | --- | --- |",
        ]
        for declaration in types:
            link = Link(page_for(declaration.file), anchor_for(declaration)).relative_to("types.md")
            label = KIND_LABELS.get(declaration.kind, declaration.kind)
            count = len(self.index.references(declaration))
            out.append(
                f"| [`{declaration.qualified_name}`]({link}) | {label} "
                f"| `{declaration.file}` | {count} |"
            )
        return "\n".join(out)

    def symbol_letter_page(self, letter: str, declarations: list[Declaration]) -> str:
        label = "Інше" if letter == "other" else letter
        heading = (
            "Символи, що не починаються з літери"
            if letter == "other"
            else f"Символи на «{letter}»"
        )
        out = [
            "---",
            f"title: {label}",
            # Excluded from search: every row here also exists on the file page it links to,
            # so indexing it doubles the payload and returns the same symbol twice.
            "search:",
            "  exclude: true",
            "---",
            "",
            f"# {heading}",
            "",
            f"{len(declarations)} оголошень.",
            "",
            "| Символ | Вид | Файл | Використань |",
            "| --- | --- | --- | --- |",
        ]
        for declaration in sorted(declarations, key=lambda item: (item.name.lower(), item.file)):
            link = Link(page_for(declaration.file), anchor_for(declaration)).relative_to(
                f"symbols/{letter.lower()}.md"
            )
            label = KIND_LABELS.get(declaration.kind, declaration.kind)
            count = len(self.index.references(declaration))
            out.append(
                f"| [`{declaration.qualified_name}`]({link}) | {label} "
                f"| `{declaration.file}` | {count} |"
            )
        return "\n".join(out)

    def hotspots_page(self) -> str:
        scored: list[tuple[int, Declaration]] = []
        rankable: list[tuple[int, Declaration]] = []
        for source in self.files:
            if source.target == "Tests":
                continue
            for declaration in source.declarations:
                count = len(self.index.references(declaration))
                scored.append((count, declaration))
                if self.index.is_countable(declaration):
                    rankable.append((count, declaration))

        # One row per *name*. Every `extension Foo` shares Foo's reference list, so without
        # this the table is six identical rows for whichever type has six extensions.
        primary: dict[str, tuple[int, Declaration]] = {}
        for count, declaration in rankable:
            existing = primary.get(declaration.name)
            if existing is None or (
                existing[1].kind == "extension" and declaration.kind != "extension"
            ):
                primary[declaration.name] = (count, declaration)

        top = sorted(primary.values(), key=lambda pair: -pair[0])[:60]
        unused = [
            declaration
            for count, declaration in scored
            if count == 0 and declaration.access not in {"private", "fileprivate"}
        ]

        out = [
            "---",
            "title: Гарячі точки",
            "search:",
            "  exclude: true",
            "---",
            "",
            "# Гарячі точки й кандидати в мертвий код",
            "",
            "Побічний продукт індексації, який корисно тримати на очах: що використовується "
            "найчастіше і що не використовується взагалі.",
            "",
            "## Найбільше звернень",
            "",
            "Змінити такий символ — дорого. Список — привід перевірити, чи не пора виділити "
            "абстракцію.",
            "",
            '!!! note "Ранжуються лише однозначні імена"',
            indent(
                "Індексатор зіставляє ідентифікатори без перевірки типів, тож число для "
                "`count`, `isEmpty` чи `body` вбирає в себе кожен `array.count` у "
                "проєкті. Такі імена — і всі, оголошені в проєкті більш ніж один раз — "
                "**виключені з цієї таблиці**: показати завищене число можна (сторінка "
                "символу про це попереджає), сортувати за ним — ні."
            ),
            "",
            "| Символ | Вид | Файл | Використань |",
            "| --- | --- | --- | --- |",
        ]
        for count, declaration in top:
            link = Link(page_for(declaration.file), anchor_for(declaration)).relative_to("hotspots.md")
            out.append(
                f"| [`{declaration.qualified_name}`]({link}) "
                f"| {KIND_LABELS.get(declaration.kind, declaration.kind)} "
                f"| `{declaration.file}` | {count} |"
            )

        out += [
            "",
            "## Нуль звернень",
            "",
            '!!! warning "Це не список мертвого коду"',
            indent(
                "Індексатор бачить лише текст Swift. Нуль звернень — це також точка входу "
                "з `@main`, метод протоколу, який викликає система, `body` в SwiftUI, "
                "`#Preview`, App Intent або дія, підключена в сторіборді ресурсів. "
                "Перевіряйте перед видаленням."
            ),
            "",
            f"Знайдено {len(unused)} таких оголошень.",
            "",
            "| Символ | Вид | Файл |",
            "| --- | --- | --- |",
        ]
        for declaration in sorted(unused, key=lambda item: (item.file, item.line))[:400]:
            link = Link(page_for(declaration.file), anchor_for(declaration)).relative_to("hotspots.md")
            out.append(
                f"| [`{declaration.qualified_name}`]({link}) "
                f"| {KIND_LABELS.get(declaration.kind, declaration.kind)} "
                f"| `{declaration.file}` |"
            )
        if len(unused) > 400:
            out.append(f"| … | | *ще {len(unused) - 400}* |")

        return "\n".join(out)


def _first_sentence(text: str) -> str:
    if not text:
        return ""
    flat = " ".join(text.split())
    for stop in (". ", "! ", "? "):
        position = flat.find(stop)
        if position != -1:
            flat = flat[: position + 1]
            break
    return flat if len(flat) <= 160 else flat[:157] + "…"
