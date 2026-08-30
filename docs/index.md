---
title: Barosense
description: Технічна документація персонального трекера метеочутливості для iPhone та Apple Watch.
hide:
  - navigation
---

# Barosense

**Персональний трекер метеочутливості для iPhone та Apple Watch.**

Barosense знімає атмосферний тиск із вбудованого барометра iPhone, зіставляє його з
короткими самозвітами про самопочуття і будує **індивідуальну** модель того, як зміни
погоди корелюють зі станом конкретної людини. Коли модель бачить характерний для цього
користувача патерн — надсилає завчасне сповіщення.

--8<-- "generated/stats.md"

!!! warning "Не медичний застосунок"
    Barosense відстежує **особисті патерни самопочуття**. Він не ставить діагнозів, не
    лікує, не запобігає захворюванням і не замінює консультацію лікаря. Це не стильова
    вимога, а обмеження App Review (Guideline 1.4.1 / 5.1.1) — див.
    [Приватність і відповідність](privacy/index.md).

## З чого почати

<div class="bs-grid" markdown>

<div class="bs-card" markdown>
### :material-map: Огляд системи
Як влаштований застосунок: таргети, межа `Shared/`, шлях даних від сенсора до екрана.

[Архітектура →](overview/architecture.md)
</div>

<div class="bs-card" markdown>
### :material-database: База даних
Чотири окремі файли SQLite, дев'ять таблиць, ER-діаграма, згенерована з коду.

[Схема →](database/index.md)
</div>

<div class="bs-card" markdown>
### :material-chart-bell-curve: ML-конвеєр
Дві мітки, реєстр ознак, forward-chaining валідація, виміряні метрики й базові лінії.

[ML →](ml/index.md)
</div>

<div class="bs-card" markdown>
### :material-book-open-variant: Довідник API
Сторінка на кожен `.swift`-файл, з описом кожного типу, методу й властивості — і
списком **усіх місць виклику**.

[Довідник →](reference/index.md)
</div>

<div class="bs-card" markdown>
### :material-shield-lock: Приватність
Що збирається, що нікуди не йде, які дозволи запитуються і навіщо саме кожен.

[Приватність →](privacy/index.md)
</div>

<div class="bs-card" markdown>
### :material-hammer-wrench: Розробка
XcodeGen, `xcodebuild`, SwiftLint, guards, CI, pre-commit hook.

[Збірка й тести →](dev/build.md)
</div>

</div>

## Ідея

Метеозалежність суб'єктивна. Хтось реагує на різке падіння тиску, хтось — на затяжний
низький, хтось узагалі не на тиск, а на недосип. Універсальні «погодні прогнози для
метеозалежних» тому й марні: вони усереднюють людей, які реагують по-різному.

Barosense не намагається вгадати «загальну» реакцію. Він навчається **на власній історії
користувача** — і прямо показує, коли даних ще замало для висновків.

## Як це працює за одну хвилину

```mermaid
flowchart LR
    subgraph sensors["Джерела"]
        BARO["Барометр iPhone<br/>CMAltimeter"]
        WK["WeatherKit<br/>прогноз на 24–96 год"]
        HK["HealthKit<br/>сон · пульс · SpO₂"]
        USER["Чек-іни користувача<br/>шкала 1–10 + теги"]
    end

    subgraph store["Сховище на пристрої"]
        DB[("4 файли SQLite<br/>SwiftData")]
    end

    subgraph pipeline["Обробка"]
        GRID["Погодинна сітка<br/>HourlyPressureGrid"]
        FEAT["Ознаки<br/>ForecastPressureFeatures<br/>HealthFeatures"]
        MODEL["Двостадійна логістична<br/>регресія + Platt"]
    end

    subgraph ui["Що бачить користувач"]
        NOW["Екран Now<br/>графік і картка ризику"]
        WATCH["Apple Watch<br/>тиск і тенденція"]
        NOTIF["Сповіщення<br/>≤3 на добу"]
    end

    BARO --> DB
    WK --> DB
    HK --> DB
    USER --> DB
    DB --> GRID --> FEAT --> MODEL
    MODEL --> NOW
    MODEL --> NOTIF
    DB --> WATCH

    style sensors stroke:#26a69a,stroke-width:2px
    style store stroke:#fb8c00,stroke-width:2px
    style pipeline stroke:#5c6bc0,stroke-width:2px
    style ui stroke:#ec407a,stroke-width:2px
```

Детальніше — [Потік даних](overview/data-flow.md).

## Незмінні обмеження проєкту

Ці п'ять правил переважають зручність. Вони записані в
[`CLAUDE.md`](https://github.com/s-rybak/barosense/blob/main/CLAUDE.md) і повторені тут,
бо решта документації постійно на них посилається.

| # | Обмеження | Де перевіряється |
| --- | --- | --- |
| 1 | **Жодних медичних тверджень** у копії, коментарях та іменах API | `scripts/ci/check-copy-vocabulary.sh` |
| 2 | **Дані про здоров'я не залишають пристрій** без окремої явної згоди | `scripts/ci/check-network-egress.sh` |
| 3 | **Дозволи HealthKit — точково**: тільки типи, у яких є споживач | `scripts/ci/check-healthkit-sync.sh` |
| 4 | **Бюджет батареї watchOS** — обов'язкове обґрунтування кожного таймера | ревʼю + `ml-spec.md` battery notes |
| 5 | **Cold start працює** з 3–7 днів історії | популяційний пріор `WellbeingRiskPrior` |

## Стек

| Область | Технологія |
| --- | --- |
| Мова / UI | Swift 6, SwiftUI |
| Мінімальна ОС | iOS 26.0 / watchOS 26.0 |
| Барометр | `CoreMotion.CMAltimeter` |
| Здоров'я | HealthKit (`HKHealthStore`, observer queries) |
| Погода | WeatherKit |
| ML | On-device логістична регресія + Platt-калібрування |
| Persistence | SwiftData (CloudKit вимкнено свідомо) |
| Голос / автоматизація | App Intents |
| Тести | XCTest |
| Проєктний файл | XcodeGen (`project.yml`) |

## Джерела правди

Документація на цьому сайті — **навігація й пояснення** поверх двох довгих специфікацій.
Числа беруться звідти; дублювати їх не можна, бо дві копії розходяться.

- [`.claude/context/ml-spec.md`](https://github.com/s-rybak/barosense/blob/main/.claude/context/ml-spec.md)
  — реєстр ознак, визначення міток, протокол валідації, battery notes.
- [`.claude/context/pressure-forecast-spec.md`](https://github.com/s-rybak/barosense/blob/main/.claude/context/pressure-forecast-spec.md)
  — ТЗ на прогноз локального тиску.

Якщо специфікація суперечить коду — баг у специфікації, і його виправляють у тому ж PR.
