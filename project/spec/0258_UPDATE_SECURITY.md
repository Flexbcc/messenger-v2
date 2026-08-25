# 0258 — Node Update Security v1

OUO не доверяет GitHub, CI, CDN или одному release key как достаточному
источнику обновления. Metadata и artifacts проверяются reference client
`python-tuf 6.0.0` по TUF 1.0.

## Roles

- `root`: offline threshold, начальный ориентир 3-of-5;
- `targets`: release approval, ориентир 2-of-3;
- `snapshot`: связывает версии metadata;
- `timestamp`: короткоживущая freshness роль.

Конкретные публичные ключи и threshold находятся только в offline-provisioned
trusted `root.json`. Discovery может сообщить URL, но не является update
authority. CI может собрать artifact, но не владеет root threshold.

## Node flow

`prepare-secure-node-update.py`:

1. требует уже provisioned `metadata/root.json`, не скачивает trust root по
   сети и запрещает writable-by-group/world root;
2. выполняет TUF refresh: threshold signatures, expiry, consistent metadata,
   rollback, target length/hash;
3. проверяет exact critical OUO custom metadata;
4. применяет monotonic `release_epoch` поверх TUF metadata versions;
   target с protocol version ниже уже установленной также отклоняется;
5. вычисляет стабильную rollout cohort из NodeID и signed release epoch;
6. скачивает проверенный artifact только в staging;
7. создаёт `0600` verified receipt.

Скрипт сознательно не устанавливает artifact, не выполняет shell из metadata,
не перезапускает контейнер и не продвигает high-watermark. Installer обязан
проверить receipt, выполнить platform-specific atomic activation/health/rollback
и только после успеха вызвать `commit_state()`.

Обязательные `targets.custom` поля:

```json
{
  "policy_version": "ouo-update-policy/1",
  "release_version": "1.2.3",
  "release_epoch": 42,
  "protocol_version": 3,
  "minimum_protocol_version": 2,
  "rollout_percent": 10
}
```

Неизвестное поле считается critical и отклоняется. Rollout 1–100%; 0 не
используется как двусмысленное «пауза/ошибка» — для паузы timestamp/targets не
публикуются либо rollout остаётся на предыдущем валидном release.

## Operational implementation

`tools/update-security/ouo_tuf.py` реализует ceremony, signed release builder и
publisher. Ceremony создаёт encrypted Ed25519 PKCS#8 keys и trusted Root
3-of-5 / Targets 2-of-3. Publisher private keys не читает: он принимает только
готовый bundle, повторно проверяет thresholds, expiry, linkage и artifact, а
затем атомарно переключает repository `current` на immutable release directory.

`install-verified-node-update.py` принимает только receipt от TUF verifier,
повторно проверяет artifact, безопасно распаковывает его в новую version
directory, атомарно переключает `current`, выполняет operator-provided restart
без shell и health gate. При ошибке symlink возвращается на предыдущую версию;
release high-watermark фиксируется только после health success.

## Ещё не закрыто этим срезом

- физическое распределение offline keys между независимыми custodians;
- reproducible build attestations.

Без этих operational частей механизм готовит и проверяет artifact, но не даёт
оснований включать unattended auto-update в публичной сети.
