# Trust/Sybil simulator

`project/scripts/run-trust-simulator.py` запускает детерминированную локальную
модель для 100, 1 000 и 10 000 L0 identities, Monte Carlo выборки committee,
peer eclipse и независимых отказов Relay.

```bash
cd /Users/apple/messenger/project
python3.11 scripts/run-trust-simulator.py \
  --output test-results/trust-simulator/latest.json
```

Модель использует production-функции CapabilityCertificate, deterministic
committee selection и guard/rotating/reserve selector. Она проверяет:

- unsigned L0 не получает Relay capability даже при большом числе identities;
- вероятность захвата 5-of-7 committee зависит от доли уже скомпрометированного
  eligible validator set;
- 10 000 single-source Sybil candidates не проходят two-source peer admission;
- одна operator group не может заполнить active set из-за hard diversity cap;
- spoofed operator diversity остаётся критическим residual risk, если большое
  число malicious nodes уже получило валидные Relay capabilities;
- single path, 3-path fallback и 6-of-10 reconstruction сравниваются при
  независимой недоступности 30% Relay;
- отдельный test фиксирует availability cost многошагового маршрута.

Peer eclipse модель условна: она начинается после capability validation и не
утверждает, что Sybil способен получить сертификат. Она специально показывает,
почему непроверяемый operator label нельзя считать защитой. Здесь пока нет
реальных ASN attestations, synthetic challenge dynamics, reputation history,
traffic-correlation модели и сетевых задержек.

Relay failure модель также намеренно ограничена: отказ каждого выбранного
Relay независим, маршруты не разделяют failure domain, а queueing, bandwidth,
latency, malicious routing и privacy/correlation не моделируются. Это baseline
доступности для сравнения transport-вариантов, а не доказательство готовности
K-of-N или production Mix Transport.

Подтверждённый локальный запуск `2026-08-19`, 2 000 committee trials на каждую
точку: `project/test-results/trust-simulator/20260819.json`. Для 100/1k/10k L0
получено `0` принятых Relay capabilities. Наблюдавшаяся доля захваченных 5-of-7
committee при 20/100 compromised validators — `0.75%`, при 34/100 — `5.6%`.
Это Monte Carlo результат конкретной детерминированной выборки, не универсальная
оценка безопасности.

Дополнительный v2 запуск на 100 trials:
`project/test-results/trust-simulator/20260819T1130Z-peer-eclipse.json`.
Результаты:

- 100 honest + 10 000 single-source spoofed-diversity Sybil: `0%` malicious
  active slots;
- 100 honest + 1 000 two-source Sybil одной operator group: active eclipse
  `0%`, malicious active slots `33.3%` (hard cap 2 из 6);
- тот же набор с неправдоподобно независимыми spoofed groups: active eclipse
  `57%` и guard capture `79%`.

Последний сценарий — не claim о текущей сети, а отрицательный test contract:
Trust/Capability и diversity evidence нельзя заменять самодекларацией ноды.

## v3: Relay failure baseline

Подтверждённый запуск `2026-08-22`, 2 000 trials на сценарий:
`project/test-results/trust-simulator/20260822-v3.json`.

- один Relay/path при 30% независимых отказов: delivery `70.35%`;
- три независимых path, достаточно одного: delivery `97.05%`;
- десять независимых shard path, достаточно 6-of-10: delivery `84.30%`.

Эти числа воспроизводимы для зафиксированного hash-derived набора trials. Они
показывают ожидаемый выигрыш multipath/K-of-N в упрощённой модели, но не
заменяют transport implementation, chaos test на физических нодах или
измерение shared network/power failure domains.
