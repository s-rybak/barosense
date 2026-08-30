---
title: Підсистеми
---

# Підсистеми

Вісім більш-менш незалежних частин. Кожна сторінка відповідає на три питання: **що робить**,
**що коштує** і **що ламається**, якщо частина не працює.

<div class="bs-grid" markdown>

<div class="bs-card" markdown>
### [:material-gauge: Тиск](pressure.md)
Барометр iPhone, епохи локації, погодинна сітка, локальна модель.
</div>

<div class="bs-card" markdown>
### [:material-weather-partly-cloudy: Погода](weather.md)
WeatherKit, бюджет 4 запити/добу, калібрування зсуву станція→MSLP.
</div>

<div class="bs-card" markdown>
### [:material-heart-pulse: Здоров'я](health.md)
Чотири типи HealthKit, observer-запити, гейт інжесту.
</div>

<div class="bs-card" markdown>
### [:material-chart-bell-curve: Ризик](risk.md)
Двостадійна логістична регресія, Platt, популяційний пріор.
</div>

<div class="bs-card" markdown>
### [:material-bell: Сповіщення](notifications.md)
Нагадування, ритм чек-інів, бюджет ≤3/добу, журнал.
</div>

<div class="bs-card" markdown>
### [:material-watch: Годинник](watch.md)
Чому він тонкий клієнт і що саме передається по `WCSession`.
</div>

<div class="bs-card" markdown>
### [:material-crown: Підписка](subscription.md)
Тріал, StoreKit, три гейтовані поверхні — і що навмисно лишається відкритим.
</div>

<div class="bs-card" markdown>
### [:material-file-pdf-box: Звіти](reports.md)
PDF за період: що входить, що ні і чому.
</div>

</div>

## Спільні правила для всіх

1. **Ніякого нового засобу пробудження без обґрунтування.** Кожен таймер, observer і
   фонове завдання мають рядок у battery notes специфікації з розрахунком вартості.
2. **Kill switch там, де є вартість.** Якщо Instruments покаже неприйнятну витрату, зміна
   має бути однорядковою константою, а не релізом із видаленням коду.
3. **Логіка — у `Shared/`, життєвий цикл — у контролері.** Це і робить кожну підсистему
   тестованою без пристрою.
