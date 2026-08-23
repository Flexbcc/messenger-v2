# 0223 — Guard / Rotating / Reserve Peer Selection v1

## Инварианты

Нода не соединяется со всей сетью и не принимает network view от одного
Discovery. Candidate допускается в selection только после проверки его signed
NodeAdvertisement/Capability и подтверждения минимум двумя configured sources.

Выбор выполняется локально через HMAC-SHA256 от непубличного persistent seed,
selection epoch, bucket и NodeID. Discovery и candidate не выбирают результат.

## Наборы

Default policy формирует:

- 2 долгоживущих guards;
- 4 rotating peers;
- 2 disconnected reserves.

Итого active set равен 6 и остаётся в целевом диапазоне 5–15. При следующем
epoch валидные guards сохраняются, rotating/reserve пересчитываются. Один NodeID
не может одновременно находиться в нескольких buckets.

`diversity_group` задаётся проверяемой deployment/network metadata. На active и
guard sets действуют отдельные hard caps. Если diversity недостаточно, selector
возвращает меньший набор с `degraded=true`, а не молча заполняет его одним
оператором. Отсутствующая group считается общей группой `unknown`.

## Fail closed

Исключаются self, неверный endpoint, неподходящая Capability, unvalidated и
single-source candidates. Два разных validated advertisements одного NodeID
являются конфликтом и останавливают selection.

## Runtime status

Protocol core, multi-source signed NodeAdvertisement ingestion и persistent
Home runtime реализованы локально (`0226`, `0227`). Runtime выключен по
умолчанию до provisioning реальных D1/D2/D3 credentials и operator/network
diversity. `enforce` mode не откатывается к legacy single-Discovery catalog и
не использует in-memory peer state после подписанного `valid_until`.

## Ограничение v1

Два источника и HMAC selection не доказывают независимость операторов. Если
тысяча уже capability-certified malicious nodes может правдоподобно заявить
тысячу разных diversity groups, локальный selector подвержен eclipse. Поэтому
Capability Trust и проверяемая diversity являются обязательными предыдущими
слоями, а не эвристиками selector.
