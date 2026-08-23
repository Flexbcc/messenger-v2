# 0240 — Unified Node Runtime v1

Одна физическая/логическая нода имеет одну Node Root Identity и независимый
набор Capability Certificates. Процесс не считается отдельной Node Identity
для каждой роли.

`NodeRuntime` связывает:

- общий registration/enrollment/heartbeat lifecycle;
- отсортированный набор включённых capabilities;
- start/stop/health hooks каждой роли;
- учёт и отмену background tasks;
- обратный порядок остановки ролей.

Runtime отклоняет capability без зарегистрированной реализации роли и не
запускается повторно. Ошибка старта роли вызывает общий graceful shutdown.
Регистрационный клиент также является управляемым: повторный start запрещён,
его enrollment/heartbeat tasks учитываются и отменяются при shutdown.

Это lifecycle-контракт. Он не объединяет базы Home/Storage и не означает, что
получение высокого Level автоматически запускает Relay/Storage/TURN: роль
должна присутствовать локально и иметь отдельную Capability.
