---
title: Потік даних
---

# Потік даних

Одна сторінка, чотири маршрути. Кожен починається із зовнішнього джерела і закінчується
на екрані або в сповіщенні.

## 1. Тиск: від сенсора до графіка

```mermaid
sequenceDiagram
    autonumber
    participant iOS as iOS<br/>(сцена / BGAppRefreshTask)
    participant Ctrl as PressureCollectionController
    participant Rec as PressureSampleRecorder
    participant CM as CMAltimeter
    participant Loc as LocationEpochRecorder
    participant DB as PressureSamples.store
    participant Watch as WatchBridge

    iOS->>Ctrl: активація сцени або фонове завдання
    Ctrl->>Rec: record(at:)
    Rec->>Rec: минуло ≥15 хв від останнього?
    alt ні
        Rec-->>Ctrl: пропустити (нічого не коштує)
    else так
        Rec->>CM: startRelativeAltitudeUpdates
        CM-->>Rec: CMAltitudeData.pressure (кПа)
        Rec->>Rec: Pressure(kilopascals:) → hPa
        Rec->>Rec: isPlausible? 800…1100 hPa
        Rec->>Loc: яка зараз епоха локації?
        Loc-->>Rec: PressureLocationEpoch.id
        Rec->>DB: upsert PersistedPressureSample
        Rec->>Watch: updateApplicationContext(знімок)
    end
```

Ключові рішення на цьому маршруті:

| Рішення | Значення | Де записано |
| --- | --- | --- |
| Мінімальний інтервал між зразками | **15 хв** | [`PressureSamplingPolicy.minimumIntervalSeconds`](../reference/Shared/Pressure/PressureSampleRecorder.md) |
| Що просимо в iOS для фонового пробудження | 15 хв (це **підлога**, не частота) | `backgroundRefreshIntervalSeconds` |
| Верхня межа зчитувань на добу | 96 | `ml-spec.md` § battery notes |
| Діапазон правдоподібності | 800–1100 hPa | [`Pressure.isPlausible`](../reference/Shared/Models/Pressure.md) |

!!! info "15 хвилин обрано для дельт, а не для самого тиску"
    Ознака `pressureHPa` толерує зразок віком до 90 хв. Але
    `pressureDeltaHPaPer3h` на погодинній сітці — це 3 точки, а на 15-хвилинній — 12.
    Роздільність дельти і є причиною частоти.

## 2. Сирий тиск → ознаки

Барометр міряє **тиск станції**. Поїздка ліфтом дає такий самий стрибок, як атмосферний
фронт. Два механізми відділяють одне від одного:

```mermaid
flowchart TB
    RAW["Сирі зразки<br/>нерегулярні, з пропусками"]
    EXC{"Зміна &gt;3 hPa<br/>за 10 хв?"}
    DROP["Відкинути:<br/>це висота, не погода"]
    GRID["Погодинна сітка<br/>HourlyPressureGrid"]
    COV["Покриття 6 год / 24 год<br/>як окрема ознака"]
    FEAT["pressureDeltaHPaPer3h<br/>pressureDeltaHPaPer6h<br/>pressureDeltaHPaPer24h<br/>pressureVolatilityHPa24h"]

    RAW --> EXC
    EXC -- так --> DROP
    EXC -- ні --> GRID
    GRID --> COV
    GRID --> FEAT
    COV --> FEAT

    style DROP stroke:#e53935,stroke-width:2px
    style FEAT stroke:#43a047,stroke-width:2px
```

**Пропуски залишаються пропусками.** Нічого не інтерполюється через дірку, бо вигадане
значення нижче за течією не відрізнити від виміряного. Замість інтерполяції модель
отримує число покриття і сама вирішує, наскільки довіряти дельті.

Поріг `3 hPa / 10 хв` — це 18 hPa/год, тобто на два порядки більше за все, що робить
атмосфера (≤2 hPa/год навіть у швидкому циклоні).

## 3. Погода: WeatherKit і калібрування зсуву

```mermaid
flowchart LR
    subgraph budget["Бюджет запитів"]
        SLOT["4 слоти на добу<br/>08 / 12 / 16 / 20<br/>перший — за годиною пробудження"]
    end
    WK["WeatherKit<br/>weather(for:including:)"]
    ARCH[("WeatherForecasts.store<br/>~240 рядків за запит")]
    CAL["PressureOffsetCalibrator<br/>медіана station − MSLP"]
    CURVE["Прогнозна крива<br/>у тиску станції"]
    CHART["Графік Now:<br/>минуле + майбутнє однією лінією"]

    SLOT --> WK --> ARCH
    ARCH --> CAL
    CAL --> CURVE
    ARCH --> CURVE
    CURVE --> CHART

    style budget stroke:#fb8c00,stroke-width:2px
```

WeatherKit віддає тиск, зведений до рівня моря (MSLP). Барометр міряє тиск станції. Різниця
навколо Києва (≈180 м) — близько **−22 hPa**, і вона не стала: Apple зводить тиск «за
спостережуваними умовами», тож зсув рухається з температурою. Тому
[`PressureOffset`](../reference/Shared/Weather/PressureOffsetCalibrator.md) зберігає не
одне число, а трійку: зсув, температуру вимірювання та кількість пар, з яких взято медіану.

Квота: 4 запити/добу × 30 = 120/місяць на пристрій, проти 500 000/місяць на членство
Apple Developer Program ≈ **4 160 пристроїв**. Перевіряти повторно, коли база наблизиться.

## 4. Чек-ін: від тапу до навчальної розмітки

```mermaid
sequenceDiagram
    autonumber
    participant U as Користувач
    participant Log as LogScreen / WatchLogView / App Intent
    participant CI as CheckIn (тип-значення)
    participant HC as CheckInHealthContextProvider
    participant St as SwiftDataCheckInStore
    participant Risk as WellbeingRiskEngine

    U->>Log: шкала 1–10, теги, ліки
    Log->>HC: зняти контекст здоров'я «зараз»
    HC-->>Log: пульс · SpO₂ · години сну (або nil)
    Log->>CI: CheckIn(timestamp:intensity:tagIDs:…)
    CI->>St: save(_:)
    St->>St: StoredCheckIn(checkIn:) → рядок
    Log->>Risk: invalidate()
    Note over Risk: наступний запит прогнозу<br/>перечитає історію
```

Три речі, які легко зрозуміти неправильно:

1. **`timestamp` — це коли користувач повідомив, а не коли рядок дійшов до сховища.**
   Ознаки рахуються на цей момент.
2. **Теги зберігаються за ідентичністю, не за текстом.** Перейменування тега не переписує
   історію чек-інів.
3. **`note` і текст ліків ніколи не стають ознакою** і ніколи не потрапляють у вихідний
   payload. Це необмежений користувацький текст.

## 5. Здоров'я: два шляхи запису

```mermaid
flowchart TB
    OBS["HKObserverQuery<br/>фонова доставка ≤1/год"]
    FG["Активація сцени<br/>пул за 7 днів"]
    GATE{"HealthIngestGate<br/>відкрито?"}
    REC["HealthSampleRecorder"]
    DB[("HealthSamples.store")]
    NOW["Рядок метрик на Now"]
    ERASE["BarosenseDataEraser"]

    OBS --> GATE
    FG --> GATE
    GATE -- ні --> STOP["нічого не писати"]
    GATE -- так --> REC --> DB
    DB --> NOW
    ERASE -. закриває гейт .-> GATE

    style STOP stroke:#e53935,stroke-width:2px
```

[`HealthIngestGate`](../reference/Shared/Health/HealthIngestGate.md) існує через конкретний
баг: «видалити мої дані» очищав лог, але спостерігачі HealthKit про це не знали і на
наступному спрацюванні клали той самий тиждень назад. Алерт обіцяв, що даних немає, — а
через хвилини вони були.

Гейт **закритий при створенні** і відкривається, коли онбординг позаду. Оскільки цей факт
живе у профілі на диску, а не в об'єкті, призупинення переживає перезапуск.

## 6. Ризик: від рядків до картки на екрані

```mermaid
flowchart LR
    P[("PressureSamples")] --> G["Погодинна сітка"]
    W[("WeatherForecasts")] --> G
    C[("CheckIns")] --> ROWS["RiskWindowRow<br/>одне вікно = 2 год<br/>дня неспання"]
    G --> ROWS
    ROWS --> FIT["Логістична регресія<br/>Newton, 10×10, ≤1000 рядків<br/>не частіше 1×/добу"]
    FIT --> PLATT["Platt-калібрування"]
    PLATT --> OUT["RiskOutlook<br/>градуйований стан"]
    OUT --> CARD["Картка на Now<br/>+ позначки на графіку"]
    OUT --> NTF["Сповіщення<br/>≤3/добу, ≤1 попередження"]

    style FIT stroke:#5c6bc0,stroke-width:2px
```

Дві стадії, дві різні мітки, дві різні одиниці прогнозу — це найлегша річ, яку можна
переплутати. Розбір: [Мітки](../ml/labels.md).

**Прогноз ніколи не подається як факт.** На екран іде градуйований стан, не «так/ні» і не
відсоток, поданий як істина. Це вимога `CLAUDE.md` і одночасно вимога App Review.

## Що коли перераховується

| Подія | Що відбувається | Вартість |
| --- | --- | --- |
| Активація сцени | зразок тиску (якщо минуло 15 хв), пул Health, реконсиляція нагадувань | ≈1 с барометра |
| `BGAppRefreshTask` | те саме без UI | ≈1 с барометра |
| Спрацювання `HKObserverQuery` | один запит за 48 год + upsert | без сенсорів |
| Новий чек-ін | `invalidate()` на ризик-моделі | наступний запит перечитає |
| Запит прогнозу ризику | мемоізовано на **15 хв** | 0, якщо в межах вікна |
| Перенавчання моделі | не частіше **1×/добу** | ~10⁵ множень-додавань |
| Слот WeatherKit | 1 мережевий запит + ~240 рядків | 4–5 разів на добу |
