# 0220 — AuthorityCheckpoint v1

`AuthorityCheckpoint` заменяет неподписанный локальный authority JSON после
bootstrap на versioned quorum transition.

## Object

Checkpoint содержит:

- `protocol_version`, `object_version`;
- строго следующий `authority_epoch`;
- `previous_hash`;
- новый `committee`, `threshold`, validator public credentials;
- bounded `issued_at`/`valid_until`;
- подписи предыдущего authority committee.

Новый committee не может подписать собственное назначение. Для перехода из
5-of-7 state требуется минимум пять действующих подписей старого committee.
Revoked/expired, duplicate и outside-committee signatures не учитываются.

`previous_hash` первого checkpoint ссылается на нормализованный bootstrap
Authority State. Дальнейшие checkpoints ссылаются на hash подписываемого тела
предыдущего checkpoint. Epoch обязан увеличиваться ровно на один; gaps,
rollback и broken chain отклоняются fail closed.

## Discovery integration

- `POST /registry/authority-checkpoints` проверяет предыдущий quorum, сохраняет
  checkpoint и передаёт его в persistent NetworkView guard;
- `GET /registry/authority-checkpoints/latest` публикует последний проверенный
  checkpoint;
- CapabilityCertificate, TrustRecord и ChallengeAssignment после принятия
  checkpoint проверяются уже относительно нового effective authority state;
- два разных quorum checkpoints одного epoch считаются equivocation и
  замораживают control plane, но не data plane.

Один Discovery пока хранит свою копию chain. Автоматический gossip/pull между
D1/D2/D3, multi-source convergence и recovery checkpoint ceremony остаются
следующим этапом. До их реализации bootstrap JSON является локальным trust
anchor и должен доставляться защищённым административным каналом.
