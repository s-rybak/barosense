"""Orchestrator: source tree in, `docs/reference/` and `docs/generated/` out.

Run it from the CLI (`scripts/docs/generate_reference.py`) or let the MkDocs hook in
`docs/hooks/reference.py` run it at the start of every build. Both call `generate()`.
"""

from __future__ import annotations

import posixpath
import re
import shutil
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path

from .model import KIND_LABELS, SourceFile
from .parser import parse_file
from .render import (
    TARGET_BLURBS,
    Renderer,
    anchor_for,
    escape_markdown,
    indent,
    page_for,
)
from .schema import Container, Entity, extract_containers, extract_entities
from .xref import ReferenceIndex

#: Source roots, in the order the reference nav lists them.
TARGETS = ("Shared", "Barosense", "BarosenseWatch", "Tests")

#: Directory purposes, for the annotated tree. A folder missing from here still appears —
#: it just carries no description, which is the visible prompt to add one.
FOLDER_NOTES: dict[str, str] = {
    "Shared": "Ядро без UI. Усе, що можна протестувати юніт-тестом, живе тут.",
    "Shared/Models": "Доменні типи-значення: `Pressure`, `CheckIn`, `WellbeingTag`, `HealthSample`, `UserProfile`.",
    "Shared/Persistence": "Протоколи сховищ, реалізації на SwiftData та in-memory дублери для тестів.",
    "Shared/Persistence/SwiftData": "`@Model`-класи основного контейнера й `@ModelActor`-сховища над ними.",
    "Shared/Pressure": "Збір із `CMAltimeter`, погодинна сітка, епохи локації, локальна модель тиску, місток на годинник.",
    "Shared/Weather": "Клієнт WeatherKit, бюджет запитів, калібрування зсуву станційного тиску до MSLP, атрибуція.",
    "Shared/Health": "Читання HealthKit, observer-запити, гейт фонової доставки, звітність про доступ.",
    "Shared/Features": "Feature engineering: ознаки тиску, ознаки здоров'я, звіт про скіл прогнозу.",
    "Shared/Risk": "Двостадійна логістична регресія, Platt-калібрування, forward-chaining, метрики, базові лінії, популяційний пріор.",
    "Shared/Insights": "Кореляція «тиск ↔ самопочуття» для екрана Insights.",
    "Shared/Notifications": "Планувальник нагадувань, ритм чек-інів, бюджет сповіщень, журнал відправленого.",
    "Shared/Report": "Побудова звіту за період — джерело даних для PDF.",
    "Shared/Subscription": "Плани, статус підписки, гейти преміум-фіч.",
    "Shared/Watch": "Контекст і payload, які iPhone передає на годинник.",
    "Shared/Location": "Абстракція над CoreLocation: доступ і фікс координат.",
    "Shared/Localization": "Мова інтерфейсу та формат годинника.",
    "Shared/CheckIn": "Голосовий чек-ін для App Intents.",
    "Shared/Diagnostics": "Логування через `os.Logger`.",
    "Barosense": "iOS-таргет: екрани, контролери, дозволи.",
    "Barosense/Navigation": "`RootView`, таб-бар із піднятою центральною дією.",
    "Barosense/Screens": "Екрани застосунку, згруповані за вкладками.",
    "Barosense/Screens/Now": "Головний екран: графік тиску, картка ризику, метрики здоров'я, прогрес навчання.",
    "Barosense/Screens/Log": "Шит чек-іну: шкала 1–10, теги, ліки.",
    "Barosense/Screens/History": "Календар за місяць / 3 місяці / рік та екран ліків.",
    "Barosense/Screens/Insights": "Картки з патернами за 120 днів.",
    "Barosense/Screens/Settings": "Профіль, мова, звіт, контакти.",
    "Barosense/Screens/Settings/Report": "Генерація PDF-звіту.",
    "Barosense/Onboarding": "Первинний флоу: умови, профіль, здоров'я, теги, патерн, преміум.",
    "Barosense/DesignSystem": "Palette, Typography, SegmentedSelector, MonthCalendar, WheelColumn.",
    "Barosense/Pressure": "`PressureCollectionController` — власник фонового збору тиску.",
    "Barosense/Weather": "Контролер прогнозу, праймер WeatherKit, атрибуція Apple.",
    "Barosense/Health": "Контролер інжесту HealthKit і лінк у застосунок «Здоров'я».",
    "Barosense/Location": "`CoreLocationService`, праймер, лінк у Налаштування.",
    "Barosense/Notifications": "Контролер нагадувань і роутер тапу по сповіщенню.",
    "Barosense/Intents": "App Intents: чек-ін і запис ліків із Siri та Shortcuts.",
    "Barosense/Subscription": "Пейвол і StoreKit.",
    "Barosense/Watch": "`WatchBridge` — надсилає знімок на годинник.",
    "Barosense/Localization": "Контролер мови інтерфейсу.",
    "Barosense/Loading": "Екран завантаження на час відкриття сховища.",
    "Barosense/Assets.xcassets": "Дві растрові картинки: іконка застосунку й логотип. Решта UI — код.",
    "Barosense/Resources": "GIF завантаження та локалізовані `InfoPlist.strings`.",
    "Barosense/Intents/": "App Intents.",
    "BarosenseWatch": "watchOS-таргет. Тонкий клієнт: показує знімок, який надіслав iPhone.",
    "BarosenseWatch/Screens": "`WatchNowView`, `WatchTrendView`, `WatchDetailsView`, `WatchLogView`.",
    "BarosenseWatch/DesignSystem": "`WatchPalette`, `BarosenseLogoMark`.",
    "Tests": "XCTest.",
    "Tests/SharedTests": "Єдиний тестовий таргет. Синтетичні фікстури, без сенсорів і мережі.",
}

GENERATED_BANNER = (
    '!!! info "Згенерована сторінка"\n'
    "    Цей файл створює `scripts/docs/generate_reference.py` під час збірки сайту. "
    "Правки, внесені сюди руками, зникнуть при наступній генерації — змінюйте "
    "`///`-коментарі в Swift-коді або сам генератор.\n"
)


@dataclass
class Project:
    """Everything the renderers need, parsed once."""

    files: list[SourceFile]
    sources: dict[str, str]
    index: ReferenceIndex
    entities: list[Entity]
    containers: list[Container]


def load(root: Path) -> Project:
    files: list[SourceFile] = []
    sources: dict[str, str] = {}
    for target in TARGETS:
        directory = root / target
        if not directory.is_dir():
            continue
        for path in sorted(directory.rglob("*.swift")):
            relative = path.relative_to(root).as_posix()
            text = path.read_text(encoding="utf-8")
            sources[relative] = text
            files.append(parse_file(relative, target, text))

    index = ReferenceIndex(files, sources)
    return Project(
        files=files,
        sources=sources,
        index=index,
        entities=extract_entities(files),
        containers=extract_containers(files, sources),
    )


class Writer:
    """Collects page text and flushes it to disk, reporting what changed."""

    def __init__(self, docs_root: Path) -> None:
        self.docs_root = docs_root
        self.pages: dict[str, str] = {}

    def write(self, relative: str, text: str) -> None:
        self.pages[relative] = text if text.endswith("\n") else text + "\n"

    def flush(self, *, clean: list[str]) -> int:
        for directory in clean:
            target = self.docs_root / directory
            if target.exists():
                shutil.rmtree(target)
        for relative, text in self.pages.items():
            path = self.docs_root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        return len(self.pages)


# --------------------------------------------------------------------------------------
# Reference section
# --------------------------------------------------------------------------------------


def _reference_index(project: Project) -> str:
    counts = Counter(source.target for source in project.files)
    declarations = Counter()
    for source in project.files:
        for declaration in source.declarations:
            declarations[declaration.kind] += 1

    total_refs = sum(len(uses) for uses in project.index.occurrences.values())

    out = [
        "---",
        "title: Довідник API",
        "---",
        "",
        "# Довідник API",
        "",
        GENERATED_BANNER,
        "",
        "Кожен `.swift`-файл проєкту має тут сторінку: призначення файлу, перелік "
        "оголошень, а для кожного оголошення — сигнатура, doc-коментар із коду й "
        "**список усіх місць, де це ім'я зустрічається**, з посиланнями на них.",
        "",
        "## Як читати",
        "",
        "| Блок на сторінці | Звідки береться |",
        "| --- | --- |",
        "| «Призначення» | `///`-коментар угорі файлу або першого документованого типу |",
        "| Сигнатура | рядок оголошення з коду, склеєний із переносів |",
        "| Опис | `///`-коментар над оголошенням |",
        "| «Де використовується» | індекс ідентифікаторів по всьому дереву |",
        "| «Зв'язки файлу» | той самий індекс, згорнутий до рівня файлів |",
        "",
        '??? question "Наскільки точний список використань"',
        indent(
            "Індексатор не має перевірки типів Swift — він зіставляє **ідентифікатори** в "
            "коді, попередньо вирізавши коментарі та рядкові літерали. Тому:\n\n"
            "* для методу враховуються лише звернення виду `name(` або `.name`, а не "
            "будь-яка згадка слова;\n"
            "* для ініціалізатора списком є виклики самого типу — `Pressure(hectopascals:)`;\n"
            "* для властивості — звернення через крапку або без неї всередині тіла "
            "власного типу;\n"
            "* якщо ім'я оголошене у проєкті кілька разів, сторінка про це **прямо каже** "
            "і дає посилання на всі однойменні оголошення;\n"
            "* якщо ім'я збігається з членом стандартної бібліотеки (`count`, `isEmpty`, "
            "`body`), сторінка теж про це каже — таке число є верхньою межею, бо в нього "
            "потрапляє кожен `array.count` у проєкті.\n\n"
            "Тобто список повний (нічого не губиться), але для неунікальних імен може "
            "бути ширшим за істину. Це свідомий компроміс: пропущений виклик шкідливіший "
            "за зайвий рядок, який видно оком. Там, де число треба **сортувати**, а не "
            "просто показати — на сторінці «Гарячі точки» — обидва класи імен виключені."
        ),
        "",
        "## Розділи",
        "",
        "| Розділ | Файлів | Що всередині |",
        "| --- | --- | --- |",
    ]
    for target in TARGETS:
        if not counts.get(target):
            continue
        out.append(
            f"| [{target}]({target}/index.md) | {counts[target]} | "
            f"{TARGET_BLURBS.get(target, '')} |"
        )

    out += [
        "",
        "## Покажчики",
        "",
        "- [Покажчик типів](types.md) — усі структури, класи, переліки, актори, протоколи",
        "- [Символи за абеткою](symbols/a.md) — повний перелік оголошень",
        "- [Гарячі точки](hotspots.md) — найчастіше вживані символи й кандидати в мертвий код",
        "",
        "## Обсяг індексу",
        "",
        "| Показник | Значення |",
        "| --- | --- |",
        f"| Файлів `.swift` | {len(project.files)} |",
        f"| Оголошень | {sum(declarations.values())} |",
        f"| Проіндексованих імен | {len(project.index.occurrences)} |",
        f"| Знайдених звернень | {total_refs} |",
        "",
        "### За видом оголошення",
        "",
        "| Вид | Кількість |",
        "| --- | --- |",
    ]
    for kind, count in declarations.most_common():
        out.append(f"| {KIND_LABELS.get(kind, kind)} (`{kind}`) | {count} |")

    return "\n".join(out)


def _summary(project: Project) -> str:
    """`SUMMARY.md` for mkdocs-literate-nav: the reference nav, built from the file list."""
    out = ["* [Огляд довідника](index.md)", "* [Покажчик типів](types.md)", "* [Гарячі точки](hotspots.md)"]

    letters = sorted({_letter(declaration.name) for source in project.files for declaration in source.declarations})
    out.append("* Символи за абеткою")
    for letter in letters:
        label = "Інше" if letter == OTHER_BUCKET else letter
        out.append(f"    * [{label}](symbols/{letter.lower()}.md)")

    for target in TARGETS:
        sources = sorted(
            (item for item in project.files if item.target == target), key=lambda item: item.path
        )
        if not sources:
            continue
        out.append(f"* [{target}]({target}/index.md)")
        grouped: dict[str, list[SourceFile]] = defaultdict(list)
        for source in sources:
            grouped[posixpath.dirname(source.path)].append(source)
        for folder in sorted(grouped):
            label = folder[len(target) :].strip("/") or "(корінь)"
            out.append(f"    * {label}")
            for source in grouped[folder]:
                name = posixpath.basename(source.path)
                out.append(f"        * [{name}]({page_for(source.path)})")

    return "\n".join(out)


#: Bucket for identifiers that do not start with a letter — operators, mostly. Spelled
#: `other` rather than `#`, which is not a usable file name or URL fragment.
OTHER_BUCKET = "other"


def _letter(name: str) -> str:
    first = name[0].upper()
    return first if first.isalpha() else OTHER_BUCKET


# --------------------------------------------------------------------------------------
# Database chapter
# --------------------------------------------------------------------------------------


def _database_page(project: Project) -> str:
    entities = {entity.name: entity for entity in project.entities}
    container_of: dict[str, Container] = {}
    for container in project.containers:
        for name in container.entities:
            container_of[name] = container

    out = [
        "---",
        "title: Схема бази даних",
        "---",
        "",
        "# Схема бази даних",
        "",
        GENERATED_BANNER,
        "",
        "Схема витягнута безпосередньо з `@Model`-класів і зі списків `Schema([...])` "
        "у коді. Окремого файлу моделі даних у SwiftData немає — схемою **є** самі класи, "
        "тому намальоване тут не може розійтися з тим, що відкриє застосунок.",
        "",
        "## Контейнери",
        "",
        "Проєкт відкриває не одну базу, а кілька окремих файлів SQLite. Кожен — окремий "
        "`ModelContainer` зі своєю схемою.",
        "",
        "| Файл на диску | Власник | Таблиць | Сутності |",
        "| --- | --- | --- | --- |",
    ]
    for container in sorted(project.containers, key=lambda item: item.store_file):
        listed = ", ".join(f"[`{name}`](#{_entity_anchor(name)})" for name in container.entities)
        owner_link = _declaration_link(project, container.owner, "generated/database-schema.md")
        out.append(
            f"| `{container.store_file}` | {owner_link} | {len(container.entities)} | {listed} |"
        )

    out += [
        "",
        "Усі файли лежать в `Application Support` контейнера застосунку — шлях будує "
        + _declaration_link(project, "BarosenseModelContainer", "generated/database-schema.md")
        + ".",
        "",
        "## Діаграми",
        "",
        "Одна діаграма на контейнер, а не одна на всю базу. Це не оформлення: контейнери "
        "**фізично різні файли SQLite**, і намальовані разом вони підказували б зв'язки, "
        "яких SwiftData між ними провести не може.",
        "",
    ]

    for container in sorted(project.containers, key=lambda item: item.store_file):
        members = [item for item in project.entities if item.name in container.entities]
        if not members:
            continue
        out.append(f"### `{container.store_file}`")
        out.append("")
        out.append("```mermaid")
        out.append("erDiagram")
        for entity in sorted(members, key=lambda item: item.name):
            out.append(f"    {entity.name} {{")
            for column in entity.columns:
                flags = []
                if column.is_unique:
                    flags.append("PK")
                if column.is_external_storage:
                    flags.append('"external storage"')
                suffix = (" " + " ".join(flags)) if flags else ""
                out.append(f"        {column.mermaid_type} {column.name}{suffix}")
            out.append("    }")

        names = {item.name for item in members}
        for left, right, label in _soft_links(project):
            if left in names and right in names:
                out.append(f'    {left} }}o--|| {right} : "{label}"')
        out.append("```")
        out.append("")

    out += _relationship_note(project)

    out += ["## Сутності", ""]

    for entity in sorted(project.entities, key=lambda item: item.name):
        container = container_of.get(entity.name)
        out.append(f"### `{entity.name}` {{ #{_entity_anchor(entity.name)} }}")
        out.append("")
        meta = [f"**Файл сховища:** `{container.store_file}`" if container else "**Файл сховища:** —"]
        meta.append(f"**Оголошено:** [`{entity.file}:{entity.line}`]({_source_page(entity.file, entity.name, project)})")
        meta.append(f"**Колонок:** {len(entity.columns)}")
        out.append(" · ".join(meta))
        out.append("")
        if entity.doc:
            out.append(escape_markdown(entity.doc))
            out.append("")

        out.append("| Колонка | Тип Swift | Обов'язкова | Ключ | Призначення |")
        out.append("| --- | --- | --- | --- | --- |")
        for column in entity.columns:
            required = "ні" if column.is_optional else "**так**"
            key = "`unique`" if column.is_unique else ("`external`" if column.is_external_storage else "—")
            note = escape_markdown(_first_line(column.doc)) or "—"
            out.append(
                f"| `{column.name}` | `{escape_markdown(column.swift_type)}` | {required} "
                f"| {key} | {note} |"
            )
        out.append("")

        if entity.embedded:
            listed = ", ".join(f"`{name}`" for name in entity.embedded)
            out.append(
                f"**Вкладені значення:** {listed} — зберігаються як `Codable`-значення "
                "всередині рядка, а не окремою таблицею."
            )
            out.append("")

    return "\n".join(out)


def _relationship_note(project: Project) -> list[str]:
    """The `@Relationship`-free design, stated where the diagrams would otherwise imply one."""
    links = _soft_links(project)
    if not links:
        return []

    container_of: dict[str, str] = {}
    for container in project.containers:
        for name in container.entities:
            container_of[name] = container.store_file

    out = [
        "## Зв'язки, які підтримує код",
        "",
        "У проєкті **жодне поле не оголошене як `@Relationship`**. Рядки пов'язані "
        "значенням ключа, а цілісність забезпечує код сховища й тести на нього.",
        "",
        "| Звідки | Колонка | Куди | В одному файлі? |",
        "| --- | --- | --- | --- |",
    ]
    for left, right, label in links:
        same = container_of.get(left) == container_of.get(right)
        out.append(
            f"| [`{left}`](#{_entity_anchor(left)}) | `{label}` "
            f"| [`{right}`](#{_entity_anchor(right)}) "
            f"| {'так' if same else '**ні**'} |"
        )

    out += [
        "",
        '!!! note "Чому не `@Relationship`"',
        indent(
            "Причини різні для кожного зв'язку, і обидві записані в коді:\n\n"
            "* `locationEpochID` — зв'язок поклав би правила каскаду епохи та вартість "
            "її вибірки на **гарячий шлях запису** таблиці, яка отримує рядок кожні "
            "п'ятнадцять хвилин, заради join'у, який калібратор робить раз на прохід;\n"
            "* `tagIdentityKeys` — ключі зберігаються рядками, а не доменним типом, щоб "
            "доменний тип був вільний змінювати форму: збережений блоб, який декодувався "
            "б прямо в нього, робив би кожну таку зміну міграцією, якої ніхто не помітив "
            "би, що пише.\n\n"
            "Наслідок спільний: те, що в реляційній базі було б зовнішнім ключем, тут є "
            "домовленістю. Сховище пише ключ, сховище його й читає, і **жодна перевірка "
            "на рівні бази цього не стереже** — стережуть тести на сховище."
        ),
        "",
    ]
    return out


#: Column-name suffixes that mark a hand-maintained foreign key.
_KEY_SUFFIXES = ("IDs", "ID", "Keys", "Key")

_CAMEL_RE = re.compile(r"[A-Z]?[a-z0-9]+")


def _soft_links(project: Project) -> list[tuple[str, str, str]]:
    """Foreign keys the code maintains without `@Relationship`, recovered by name.

    Heuristic, and it has to be: nothing in the schema marks these. A column whose name
    ends in `ID`/`Key` (singular or plural) is matched against every other entity by its
    camelCase tokens — `tagIdentityKeys` → `tag` → `StoredWellbeingTag`. Tokens shorter
    than three characters are ignored, which is what keeps `id` from matching everything.
    """
    names = {entity.name for entity in project.entities}
    links: list[tuple[str, str, str]] = []

    for entity in project.entities:
        for column in entity.columns:
            suffix = next((item for item in _KEY_SUFFIXES if column.name.endswith(item)), None)
            if suffix is None:
                continue
            stem = column.name[: -len(suffix)]
            tokens = [token.lower() for token in _CAMEL_RE.findall(stem) if len(token) >= 3]
            if not tokens:
                continue

            match = next(
                (
                    candidate
                    for candidate in sorted(names)
                    if candidate != entity.name
                    and any(token in candidate.lower() for token in tokens)
                ),
                None,
            )
            if match:
                links.append((entity.name, match, column.name))
    return links


def _entity_anchor(name: str) -> str:
    return "entity-" + name.lower()


def _declaration_link(project: Project, type_name: str, from_page: str) -> str:
    for source in project.files:
        for declaration in source.declarations:
            if declaration.name == type_name and declaration.is_type:
                target = posixpath.relpath(
                    "reference/" + page_for(declaration.file), posixpath.dirname(from_page)
                )
                return f"[`{type_name}`]({target}#{anchor_for(declaration)})"
    return f"`{type_name}`"


def _source_page(file: str, type_name: str, project: Project) -> str:
    return posixpath.relpath("reference/" + page_for(file), "generated")


def _first_line(doc: str) -> str:
    if not doc:
        return ""
    line = doc.strip().splitlines()[0].strip()
    return line if len(line) <= 150 else line[:147] + "…"


# --------------------------------------------------------------------------------------
# Structure and graph
# --------------------------------------------------------------------------------------


def _tree_page(project: Project, root: Path) -> str:
    counts: Counter[str] = Counter()
    lines_by_folder: Counter[str] = Counter()
    for source in project.files:
        folder = posixpath.dirname(source.path)
        counts[folder] += 1
        lines_by_folder[folder] += source.line_count

    folders = sorted(counts)
    out = [
        "---",
        "title: Дерево репозиторію",
        "---",
        "",
        "# Дерево репозиторію",
        "",
        GENERATED_BANNER,
        "",
        "Перелічені лише теки з Swift-кодом; кількість файлів і рядків рахується під час "
        "збірки сайту, тому не старіє.",
        "",
        "```text",
        ".",
    ]

    rendered: set[str] = set()
    for folder in folders:
        parts = folder.split("/")
        for depth in range(len(parts)):
            prefix = "/".join(parts[: depth + 1])
            if prefix in rendered:
                continue
            rendered.add(prefix)
            pad = "│   " * depth + "├── "
            own = counts.get(prefix, 0)
            below = sum(value for key, value in counts.items() if key == prefix or key.startswith(prefix + "/"))
            badge = f"  ({below} файлів)" if below else ""
            out.append(f"{pad}{parts[depth]}/{badge}")
    out += [
        "├── project.yml            маніфест XcodeGen — джерело правди про таргети",
        "├── scripts/ci/            guards, які виконуються локально й у CI",
        "├── scripts/docs/          генератор цієї документації",
        "├── docs/                  ця документація (MkDocs Material)",
        "├── .githooks/             pre-commit: SwiftLint + збірка симулятора",
        "├── .github/workflows/     checks.yml (Ubuntu) і tests.yml (macOS)",
        "└── .claude/               контекст і процедури для AI-агента + специфікації",
        "```",
        "",
        "## Теки з кодом",
        "",
        "| Тека | Файлів | Рядків | Призначення |",
        "| --- | --- | --- | --- |",
    ]

    for folder in folders:
        note = FOLDER_NOTES.get(folder, "—")
        link = posixpath.relpath(f"reference/{folder}/index.md", "generated")
        target_root = folder.split("/")[0]
        index_link = posixpath.relpath(f"reference/{target_root}/index.md", "generated")
        out.append(
            f"| [`{folder}/`]({index_link}) | {counts[folder]} | {lines_by_folder[folder]} | {note} |"
        )

    return "\n".join(out)


def _graph_page(project: Project) -> str:
    """Folder-level dependency graph per target, drawn from the same occurrence index."""
    edges: Counter[tuple[str, str]] = Counter()
    for source in project.files:
        if source.target == "Tests":
            continue
        origin = posixpath.dirname(source.path)
        for dependency in project.index.file_dependencies(source):
            destination = posixpath.dirname(dependency)
            if destination == origin or dependency.startswith("Tests/"):
                continue
            edges[(origin, destination)] += 1

    out = [
        "---",
        "title: Граф модулів",
        "---",
        "",
        "# Граф залежностей між теками",
        "",
        GENERATED_BANNER,
        "",
        "Ребро `A → B` означає: хоча б один файл у теці `A` називає тип, оголошений у "
        "теці `B`. Товщина не показана — число на ребрі це кількість пар файлів.",
        "",
        '!!! tip "Що тут перевіряти"',
        indent(
            "Стрілок із `Shared/…` у `Barosense/…` або в `BarosenseWatch/…` бути не "
            "може: ядро не має знати про платформні таргети. Якщо така з'явилася — межа "
            "модулів порушена, і це видно на цій сторінці раніше, ніж у ревʼю."
        ),
        "",
    ]

    for target in ("Shared", "Barosense", "BarosenseWatch"):
        subset = {
            pair: weight
            for pair, weight in edges.items()
            if pair[0].startswith(target + "/") or pair[0] == target
        }
        if not subset:
            continue
        out += [f"## Із `{target}/`", "", "```mermaid", "graph LR"]
        nodes = {node for pair in subset for node in pair}
        for node in sorted(nodes):
            out.append(f'    {_node_id(node)}["{node}"]')
        for (origin, destination), weight in sorted(subset.items(), key=lambda item: -item[1]):
            if weight < 2 and target != "BarosenseWatch":
                continue
            out.append(f"    {_node_id(origin)} -->|{weight}| {_node_id(destination)}")
        out += ["```", ""]

    violations = [pair for pair in edges if pair[0].startswith("Shared") and not pair[1].startswith("Shared")]
    if violations:
        out += [
            '!!! failure "Порушення межі модулів"',
            indent(
                "Знайдено ребра з `Shared/` назовні:\n\n"
                + "\n".join(f"* `{origin}` → `{destination}`" for origin, destination in sorted(violations))
            ),
            "",
        ]
    else:
        out += [
            '!!! success "Межа модулів ціла"',
            indent("Жоден файл у `Shared/` не називає тип із платформного таргета."),
            "",
        ]

    return "\n".join(out)


def _node_id(path: str) -> str:
    return path.replace("/", "_").replace(".", "_").replace("-", "_")


# --------------------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------------------


def _stats_snippet(project: Project) -> str:
    """The number strip on the home page.

    A snippet rather than prose so the figures on the landing page are the figures of the
    tree that was just parsed. A hand-typed "289 files" is wrong within a week.
    """
    declarations = sum(len(source.declarations) for source in project.files)
    references = sum(len(uses) for uses in project.index.occurrences.values())
    lines = sum(source.line_count for source in project.files)
    tests = sum(1 for source in project.files if source.target == "Tests")

    cells = [
        (f"{len(project.files)}", "файлів Swift"),
        (f"{lines:,}".replace(",", " "), "рядків коду"),
        (f"{declarations}", "оголошень"),
        (f"{references:,}".replace(",", " "), "звернень проіндексовано"),
        (f"{len(project.entities)}", "таблиць у базі"),
        (f"{tests}", "тестових файлів"),
    ]
    body = "".join(
        f'<div class="bs-stat"><strong>{value}</strong><span>{label}</span></div>'
        for value, label in cells
    )
    return f'<div class="bs-stats">{body}</div>'


def generate(root: Path, docs_root: Path) -> tuple[int, Project]:
    """Build every generated page. Returns the page count and the parsed project."""
    project = load(root)
    renderer = Renderer(project.files, project.index)
    writer = Writer(docs_root)

    writer.write("reference/index.md", _reference_index(project))
    writer.write("reference/SUMMARY.md", _summary(project))
    writer.write("reference/types.md", renderer.types_index())
    writer.write("reference/hotspots.md", renderer.hotspots_page())

    by_letter: dict[str, list] = defaultdict(list)
    for source in project.files:
        for declaration in source.declarations:
            by_letter[_letter(declaration.name)].append(declaration)
    for letter, declarations in by_letter.items():
        writer.write(f"reference/symbols/{letter.lower()}.md", renderer.symbol_letter_page(letter, declarations))

    for target in TARGETS:
        if any(source.target == target for source in project.files):
            writer.write(f"reference/{target}/index.md", renderer.target_index(target))

    for source in project.files:
        writer.write(f"reference/{page_for(source.path)}", renderer.file_page(source))

    writer.write("generated/stats.md", _stats_snippet(project))
    writer.write("generated/database-schema.md", _database_page(project))
    writer.write("generated/project-tree.md", _tree_page(project, root))
    writer.write("generated/module-graph.md", _graph_page(project))

    count = writer.flush(clean=["reference", "generated"])
    return count, project
