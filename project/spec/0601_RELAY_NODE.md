# 0601. Relay node

## Статус
Basic Relay реализован; Mix/Sphinx остаётся следующим privacy layer.

## Назначение
Узел, обеспечивающий пересылку пакетов между клиентами/узлами, когда прямое
соединение невозможно (Relay Node, [[0004_GLOSSARY]]).

## Ответственности
- Приём Packet, определение следующего хопа на маршруте (см. [0203_ROUTING.md](0203_ROUTING.md)) и его пересылка.
- Проверка подписи Packet перед пересылкой (Zero Trust, см. [0300_CRYPTO.md](0300_CRYPTO.md)).
- Публикация собственной доступности как Capability в Discovery Node.

Relay Node **не читает** и не может прочитать содержимое сообщений — оно
защищено E2EE, к которому у Relay нет ключа (Single Responsibility,
Privacy First).

## Выбор relay node
Отправляющая сторона (Home Node или Client) выбирает Relay Node из списка,
полученного от Discovery Node, на основе доступных метрик: заявленной
географии, наблюдаемой задержки и текущей нагрузки. При недоступности
выбранного Relay Node используется следующий по списку (см.
[0103_NETWORK.md](0103_NETWORK.md) → Отказоустойчивость).

## Ограничения (rate limiting, антизлоупотребление)
Relay Node ограничивает частоту запросов по источнику соединения (token
bucket на транспортное соединение), не требуя постоянной идентификации
отправителя — это защищает от злоупотребления пропускной способностью, не
создавая при этом дополнительный источник метаданных о личности
отправителя.

## Метаданные, видимые relay node
Relay Node видит: адрес предыдущего и следующего хопа, размер и время
прохождения Packet. Relay Node не видит: содержимое Message, полный
маршрут пакета, Identity отправителя/получателя за пределами
маршрутизируемого одноразового `sender_ref` (см.
[0201_PACKETS.md](0201_PACKETS.md), [0203_ROUTING.md](0203_ROUTING.md) →
приватность маршрутизации).

## Масштабирование и балансировка нагрузки
Relay Node не хранит состояние сессии дольше времени пересылки одного
Packet (Stateless Communication, [[0003_ENGINEERING_PRINCIPLES]]), что
позволяет свободно добавлять и удалять экземпляры Relay Node без
координации с message state. Любой участник может поднять ноду, но обслуживать
чужой transit traffic она начинает только после получения отдельной Relay
Capability через Trust Protocol.

## Реализованный Basic data plane

HTTP и persistent WSS скрыты за одним Transport Adapter. WSS использует binary
batches, строгую persistent link sequence, per-hop cell ID/expiry и bounded
connection/frame/cell/time budgets. Capability Certificate сужает connection,
cell и bandwidth quotas. Target допускается только при валидных Node Identity,
NodeAdvertisement и Home Capability. Повтор envelope на одном Relay hop
отклоняется отдельным replay tag.

Relay пока видит target Home URL и legacy endpoint packet metadata. Это честный
Basic Relay baseline, не Mix Network.

Target Home и аварийный L2+ hub выбираются не по неподписанному каталогу
одного Discovery. Relay требует совпадающее security-состояние от настроенного
кворума Discovery, локально проверяет Transport Certificate и Capability, а
при конфликтующем quorum-backed view исключает ноду из маршрутизации.
Кэш маршрута ограничен самым ранним expiry Advertisement, Observation,
Operational/Capability/Transport credentials.

## Реализованный Mix ingress foundation

`POST /mix/ingress` принимает подписанные запросы только от Home/Relay peers,
применяет certified traffic quota, проверяет opaque fixed-size envelope,
вызывает injected onion provider и сохраняет hash per-hop replay tag в bounded
TTL store. Next-hop dispatch проходит через bounded Mix Pool с jitter; ошибка
downstream возвращает неотправленную часть batch в очередь до expiry.

Без reviewed Sphinx provider endpoint отвечает fail closed. Relay-only role не
может принять final payload — это право destination ingress/Home handler.
