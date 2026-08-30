---
title: Структура проєкту
---

# Структура проєкту

Анотоване дерево репозиторію. Правило одне: **усе, що може жити в `Shared/`, живе
в `Shared/`.**

!!! tip "Актуальні цифри — на сусідній сторінці"
    Кількість файлів і рядків у кожній теці рахується під час збірки сайту:
    [Дерево репозиторію](../generated/project-tree.md). Тут — пояснення, чому теки саме
    такі.

## Верхній рівень

```text
Barosense/          iOS-таргет — SwiftUI-екрани, контролери, дозволи
BarosenseWatch/     watchOS-таргет — циферблатні екрани, читає готовий знімок з iPhone
Shared/             домен, сервіси, ознаки, ризик-модель — без UI, покрито юніт-тестами
Tests/SharedTests/  XCTest — синтетичні фікстури, без HealthKit і CoreMotion
docs/               ця документація (Material for MkDocs)
scripts/ci/         guards, які виконуються локально й у CI
scripts/docs/       генератор довідника API
.githooks/          pre-commit: SwiftLint + збірка симулятора
.github/workflows/  checks.yml (Ubuntu) і tests.yml (macOS)
.claude/            контекст і процедури для AI-агента + довгі специфікації
project.yml         маніфест XcodeGen — єдине джерело правди про таргети
.swiftlint.yml      стиль + три кастомні правила
mkdocs.yml          конфігурація сайту документації
```

`Barosense.xcodeproj` **не комітиться** — генерується з `project.yml`. Це прибирає
merge-конфлікти у проєктному файлі. Деталі — [Збірка й тести](../dev/build.md).

## `Shared/` — ядро

Кожна тека — одна відповідальність. UI-фреймворки сюди імпортувати не можна.

| Тека | Що всередині | Довідник |
| --- | --- | --- |
| `Models/` | Доменні типи-значення: `Pressure` (hPa), `PressureSample`, `CheckIn`, `WellbeingLabel`, `WellbeingTag`, `HealthSample`, `MedicationEntry`, `UserProfile`, `ForecastPressurePoint`, `PressureLocationEpoch` | [→](../reference/Shared/index.md) |
| `Persistence/` | Протоколи сховищ (`CheckInStore`, `PressureSampleStore`, …), реалізації на SwiftData і **in-memory дублери для тестів** | [→](../database/index.md) |
| `Pressure/` | Збір із `CMAltimeter`, `PressureSampleRecorder`, погодинна сітка, епохи локації, `LocalPressureModel`, місток на годинник | [→](../subsystems/pressure.md) |
| `Weather/` | Клієнт WeatherKit, бюджет запитів, калібрування зсуву станційного тиску до MSLP, атрибуція | [→](../subsystems/weather.md) |
| `Health/` | Читання HealthKit, observer-запити, `HealthIngestGate`, звітність про доступ | [→](../subsystems/health.md) |
| `Features/` | Feature engineering: `ForecastPressureFeatures`, `HealthFeatures`, `ForecastSkillReport` | [→](../ml/features.md) |
| `Risk/` | Двостадійна логістична регресія, Platt-калібрування, forward-chaining, метрики, базові лінії, популяційний пріор | [→](../subsystems/risk.md) |
| `Insights/` | Кореляція «тиск ↔ самопочуття» і патерн-нотатка для екрана Insights | [→](../reference/Shared/index.md) |
| `Notifications/` | Планувальник нагадувань, ритм чек-інів, бюджет сповіщень, журнал відправленого | [→](../subsystems/notifications.md) |
| `Report/` | Побудова звіту за період — джерело даних для PDF | [→](../subsystems/reports.md) |
| `Subscription/` | Плани, статус, гейти преміум-фіч | [→](../subsystems/subscription.md) |
| `Watch/` | Контекст і payload, які iPhone передає на годинник | [→](../subsystems/watch.md) |
| `Location/` | Абстракція локації: доступ і фікс координат | [→](../reference/Shared/index.md) |
| `Localization/` | Мова інтерфейсу і формат годинника | [→](../reference/Shared/index.md) |
| `CheckIn/` | Голосовий чек-ін для App Intents | [→](../reference/Shared/index.md) |
| `Diagnostics/` | Логування через `os.Logger` | [→](../reference/Shared/index.md) |

## `Barosense/` — iOS

```text
Navigation/     RootView, таб-бар із піднятою центральною дією
Screens/
  Now/          головний екран: графік тиску, картка ризику,
                метрики здоров'я, прогрес навчання
  Log/          шит чек-іну — шкала 1–10, теги, ліки
  History/      календар за місяць / 3М / рік + екран ліків
  Insights/     картки з патернами за 120 днів
  Settings/     профіль, мова, звіт, контакти
Onboarding/     умови, профіль, здоров'я, теги, патерн, преміум
DesignSystem/   Palette, Typography, SegmentedSelector, MonthCalendar, WheelColumn
Pressure/       PressureCollectionController — власник фонового збору
Weather/        WeatherForecastController, праймер WeatherKit, атрибуція Apple
Health/         HealthIngestController, лінк у застосунок «Здоров'я»
Location/       CoreLocationService, праймер, лінк у Налаштування
Notifications/  контролер нагадувань, роутер тапу по сповіщенню
Intents/        App Intents: чек-ін і запис ліків із Siri / Shortcuts
Subscription/   пейвол, StoreKit
Watch/          WatchBridge — надсилає знімок на годинник
Loading/        LaunchLoadingView — анімація на час відкриття сховища
```

Патерн: `*Controller` в iOS-таргеті **володіє життєвим циклом** (сцена, дозвіл, фонове
завдання), а вся логіка, яку можна протестувати, лежить у відповідній теці `Shared/`.

## `BarosenseWatch/` — watchOS

Годинник **не має власного барометра в цьому застосунку** — він отримує один
`PressureDisplaySnapshot` через `WatchConnectivityPressureLink` і показує його.

```text
Screens/        WatchNowView, WatchTrendView, WatchDetailsView, WatchLogView
DesignSystem/   WatchPalette, BarosenseLogoMark
```

Чому так — [Годинник](../subsystems/watch.md).

## `Tests/SharedTests/`

Один тестовий таргет. Умова: **конвеєр повинен запускатися з простого XCTest на
синтетичному вході** — без `HKHealthStore`, без `CMAltimeter`, без мережі.

Дві опорні фікстури:

- `SyntheticTraceFixture` — 120-денна траса з дослідницького ноутбука;
- `SklearnFixture` — звірка коефіцієнтів із scikit-learn.

Перелік обов'язкових фікстур — [`ml-spec.md` § 8](https://github.com/s-rybak/barosense/blob/main/.claude/context/ml-spec.md).

## Кастомні правила SwiftLint

Три правила тримають межі, описані вище:

| Правило | Що забороняє | Рівень |
| --- | --- | --- |
| `shared_ui_free` | `import SwiftUI / UIKit / WatchKit` усередині `Shared/` | error |
| `no_mainactor_task_hop` | стрибок на `MainActor` через `Task { @MainActor in }` | error |
| `no_new_combine` | нові залежності від Combine | warning |

Запускаються локально pre-commit-хуком і в CI зі `--strict` (ворнінг = помилка).

## Куди далі

- [Дерево репозиторію](../generated/project-tree.md) — повний перелік із цифрами
- [Граф модулів](../generated/module-graph.md) — хто на кого посилається
- [Довідник API](../reference/index.md) — сторінка на кожен файл
