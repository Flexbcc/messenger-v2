# 0221 — Authenticated AuthorityCheckpoint Gossip v1

AuthorityCheckpoint должен сходиться между D1/D2/D3 без превращения HTTP или
одного Discovery в authority.

## Source announcement

Каждый gossip item содержит quorum-signed `AuthorityCheckpoint` и короткоживущий
`AuthorityAnnouncement`:

- source self-certifying NodeID;
- authority epoch и checkpoint hash;
- UUID, announced/expiry timestamps;
- подпись Operational Key source Discovery.

Receiver не доверяет полям HTTP-ответа. Он независимо проверяет:

1. checkpoint quorum и hash chain;
2. Node Identity источника из локального Discovery state;
3. текущую quorum-signed capability `discovery` источника;
4. Operational signature, expiry и replay announcement;
5. соответствие announcement epoch/hash фактическому checkpoint.

Во время одного authority transition допускается bounded overlap: source
Discovery может объявить новый checkpoint с capability, выданной непосредственно
предыдущим authority. Overlap ограничен TTL announcement (не более 10 минут) и
нужен для получения независимых наблюдений уже после локального применения
checkpoint. Более старые authority states не принимаются.

## Pull protocol

- `GET /registry/authority-checkpoints/gossip?after_epoch=N` возвращает chain в
  ascending epoch order, максимум 100 объектов, и отдельно подписанный `head`;
- `head` возвращается даже когда после `N` нет новых checkpoint'ов: receiver
  может обнаружить сертифицированный Discovery со stale view, не откатывая
  локальную authority chain;
- `POST /registry/authority-checkpoints/gossip` принимает один подписанный item;
- optional background pull использует только configured origins из
  `AUTHORITY_GOSSIP_PEERS`, не следует redirects и игнорирует environment proxy;
- peer URL обязан быть чистым `http(s)` origin без credentials/query/fragment;
- production peers должны находиться за authenticated private overlay и TLS.

Одинаковый checkpoint от нескольких сертифицированных Discovery увеличивает
независимость network view, не создавая вторую запись chain. Разные валидные
quorum checkpoints одного epoch являются equivocation evidence и переводят
control plane в sticky Safe Mode. Data plane продолжает работать.
Три и более подписанных source head с gap больше локального лимита также
включают Safe Mode как признак stale/eclipsed network view.

## Ограничения v1

- operator/diversity independence Discovery пока задаётся deployment policy;
- gossip не снимает Safe Mode и не заменяет recovery ceremony;
- bootstrap authority state остаётся локальным trust anchor;
- публичный Internet endpoint для gossip не требуется и по умолчанию механизм
  выключен.
