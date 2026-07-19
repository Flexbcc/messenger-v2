# Capacity & admission control

> Статус: **модель + анимированная модель в визуализаторе**.

## Распределение ресурсов — гарантированный приоритет, не жёсткая доля

Не использовать модель «40% пользователю / 60% сети» — она неэффективна.

```
Personal workload:
- всегда выше по приоритету;
- может занять до 100% при необходимости.

Community workload:
- использует только свободные ресурсы;
- имеет настроенные максимумы;
- вытесняема (preemptible);
- останавливается раньше, чем деградируют личные сервисы.
```

Пример:

```
Нет личной нагрузки:      Personal 5%  · Community 60% · Reserve 35%
Средняя личная нагрузка:  Personal 60% · Community 30% · Reserve 10%
Высокая личная нагрузка:  Personal 95% · Community 0–5%
```

Отдельные лимиты: CPU, RAM, I/O, disk space, network throughput, monthly traffic,
passive connections, active streams, file relay tasks.

## Admission controller

Нода не ждёт полного отказа. Контроллер анализирует: CPU usage/pressure, memory
usage/pressure, swap, disk free/I-O latency, network throughput, packet loss,
connection count, active transfers, queue size, request latency, timeout rate,
error rate.

## Состояния

| Состояние | Поведение |
|---|---|
| **NORMAL** | обслуживает личные задачи и общую сеть |
| **BUSY** | продолжает текущее, ограничивает новые тяжёлые задания |
| **OVERLOADED** | не принимает новые задания общей сети; маршрутизаторы выбирают другие ноды |
| **CRITICAL** | отключает общественные функции; оставляет управление, критические личные сообщения, завершение безопасных операций, восстановление и обновление |

## Capacity Advertisement

Нода сообщает сети текущую доступность (подсказка, не абсолютная истина):

```json
{ "node_id": "node_123", "status": "busy",
  "capabilities": { "relay": true, "temporary_storage": true, "discovery": false, "witness": true },
  "available": { "connections": 240, "relay_streams": 3, "storage_bytes": 21474836480, "egress_mbps": 12 },
  "software": { "version": "2.3.1", "security_state": "supported" },
  "expires_at": "...", "signature": "..." }
```

Сеть учитывает историю ноды: успешные передачи, ошибки, uptime, latency,
стабильность, жалобы, расхождение заявленной и фактической ёмкости.

## Реализовано в визуализаторе

Сценарии «Рост личной нагрузки» и «Перегрузка: NORMAL → CRITICAL»: анимируются
CPU/RAM/диск/соединения, сплит Personal/Community/Reserve и бейдж состояния;
общественные задания отклоняются и capability отключаются при росте нагрузки.

## Открытые вопросы

- Пороги переходов между состояниями и гистерезис.
- Реальные единицы измерения pressure и их источники в ОС.
