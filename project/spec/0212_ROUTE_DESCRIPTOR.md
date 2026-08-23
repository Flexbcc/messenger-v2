# 0212 — RouteDescriptor v1

## Назначение

После bootstrap пользователи передают маршруты внутри E2EE. Discovery не
создаёт RouteDescriptor и не является постоянным route authority.

## Объект

`ouo-route-descriptor/1` содержит self-certifying `user_id`, `identity_version`,
монотонный `route_epoch`, до восьми ingress descriptors, окно действия,
`previous_hash`, commitment следующего descriptor и подпись Identity Root.

Ingress descriptor содержит только `node_id`, HTTPS/WSS endpoint и transport.
Home Node пользователя может не входить в опубликованный ingress set.

## Current / next / next+1

Endpoint хранит highest seen identity version и route epoch. Будущий descriptor
можно проверить заранее с `allow_future`, но активировать только в его окне.
Переход требует последовательный epoch, hash предыдущего полного descriptor и,
если объявлен, совпадающий commitment следующего immutable route payload.

Неизвестные поля, rollback, подмена ingress, неверная подпись и истёкшее окно
отклоняются fail closed. Небольшой clock-skew допускается, а перекрытие окон
задаётся самими соседними descriptors.

## Discovery recovery cache

Discovery может хранить точный endpoint-signed descriptor как bootstrap/recovery
helper, но не создаёт и не переподписывает его. Перед первой публикацией должен
существовать валидированный BootstrapRecord с тем же `user_id`, Identity key и
`identity_version`.

- `POST /registry/route-descriptors` проверяет подпись, expiry, highest epoch,
  последовательный `previous_hash` и optional next commitment;
- same-epoch identical object идемпотентен, другой object конфликтует;
- gap и rollback отклоняются fail closed;
- `GET /registry/route-descriptors/{user_id}` возвращает не более трёх последних
  объектов в ascending epoch order;
- более старая route history удаляется для metadata minimization.

Recovery cache реплицируется между D1/D2/D3 вместе с BootstrapRecord через
bounded pull-gossip. RouteDescriptor принимается только после соответствующей
Identity записи; если порядок доставки обратный, descriptor будет повторно
получен в следующем gossip cycle. Конфликт одного route epoch включает Safe
Mode для критического control plane.

Этот cache не заменяет целевой обмен RouteDescriptor внутри E2EE и не делает
Discovery постоянным router или route authority.

## Home Route Runtime

Home получает BootstrapRecord и до трёх RouteDescriptor параллельно из
нескольких независимых Discovery. Каждый объект проверяется локально. Для
результата требуется совпадающий объект минимум от настроенного количества
источников; same-epoch split view отклоняется fail closed.

Runtime сохраняет на диске highest seen `identity_version`, `record_version`,
`route_epoch` и hash последнего descriptor атомарной заменой файла с правами
`0600`. После рестарта rollback ниже high-watermark не принимается. Два
предшествующих route epoch разрешены только для восстановления цепочки
current/next/next+1; новый highest epoch обязан быть не ниже сохранённого.

Из согласованной цепочки наружу выдаётся только descriptor, активный в текущем
временном окне, плюс максимум два будущих. Режимы `off`, `report`, `enforce`
позволяют миграцию со старого `user → home` API без небезопасной автоматической
подмены существующего data plane.
