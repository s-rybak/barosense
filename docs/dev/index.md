---
title: Розробка
---

# Розробка

| Сторінка | Що всередині |
| --- | --- |
| [Збірка й тести](build.md) | XcodeGen, `xcodebuild`, симулятори, локальний прогін |
| [Конвенції коду](conventions.md) | Swift-стиль, межі модулів, конкурентність, розміри дифів |
| [CI та guards](ci.md) | Два workflow, п'ять guard-скриптів, pre-commit hook |
| [Як влаштована ця документація](documentation.md) | MkDocs, генератор довідника, як додати сторінку |

## Швидкий старт

```bash
brew install xcodegen
xcodegen generate
open Barosense.xcodeproj
```

```bash
git config core.hooksPath .githooks
```

```bash
scripts/ci/run-all.sh      # guards — секунди, без Xcode
scripts/ci/run-tests.sh    # збірка + XCTest на симуляторі
```

## Правило, яке легко порушити випадково

!!! danger "Коміти робить людина"
    Агент **ніколи** не виконує `git commit`, `git add` чи `git push` — навіть коли його
    про це просять. Зміна лишається в робочій копії, агент каже, що в ній, і передає
    команду. Коміт — це підпис людини під тим, що диф прочитано.

    Процедура — [`human_approval`](https://github.com/s-rybak/barosense/blob/main/.claude/skills/human_approval/SKILL.md).

## Що потрібно фізично

| Що | Навіщо | Обов'язково? |
| --- | --- | --- |
| Xcode 26+ | Збірка під iOS 26 / watchOS 26 | так |
| XcodeGen | `.xcodeproj` не комітиться | так |
| SwiftLint | pre-commit і CI | так |
| Платний Apple Developer акаунт | WeatherKit і HealthKit capabilities | для збірки на пристрій |
| Фізичний iPhone | **Барометр не працює в симуляторі** | для тестування збору тиску |
| Python 3.11+ | Збірка сайту документації | лише для документації |
