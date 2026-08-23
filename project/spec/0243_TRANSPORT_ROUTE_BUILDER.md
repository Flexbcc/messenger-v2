# 0243 — Local Transport Route Builder v1

Discovery возвращает подписанные/certified сведения о кандидатах, но не задаёт
готовый маршрут. Отправляющая нода локально:

1. повторно проверяет root-signed Transport Certificate;
2. принимает только trusted, online и certified Relay;
3. исключает собственную ноду и запрещённые NodeID;
4. выбирает 2–4 уникальных Relay hops через CSPRNG;
5. по возможности не повторяет IPv4 /24, IPv6 /48 или hostname group.

IP/hostname diversity — вспомогательный сигнал, а не доказательство разных
операторов. При недостатке кандидатов построение маршрута завершается ошибкой;
скрытого перехода к открытому direct route нет.

Основной privacy path использует peer view, где одинаковый Transport
Certificate независимо наблюдали не менее двух Discovery. Local registry view
остаётся доступен для Basic Relay/migration, но не заменяет source quorum.

Полный обычный onion route содержит выбранные Relay hops и одну destination
Home последней: итого 3–5 layers. Home в середине маршрута и Relay в роли
terminator отклоняются. SURB использует тот же role-binding, но скрывает
destination path от отправителя.
