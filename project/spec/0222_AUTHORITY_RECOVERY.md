# 0222 — Emergency AuthorityRecovery v1

Обычный L5 quorum не может восстановить сеть после собственного полного
захвата. Для catastrophic recovery используется отдельная offline policy,
например 3-of-5 физических ключей.

## Trust separation

- private recovery keys никогда не находятся на Discovery, CI или production;
- ноды получают только public recovery state через
  `RECOVERY_AUTHORITY_STATE_PATH`;
- обычные validator keys не считаются recovery keys;
- admin secret является дополнительным admission barrier, но не заменяет
  threshold signatures.

## Recovery object

`AuthorityRecovery` содержит:

- UUID, version и ограниченный reason code;
- highest compromised authority epoch;
- unsigned ordinary-format replacement checkpoint с новым authority set;
- ceremony issue/expiry (не более 24 часов);
- recovery committee/threshold;
- signatures offline recovery keys.

Replacement checkpoint обязан иметь epoch выше covered compromised epoch и не
может содержать подписи normal authority. Весь replacement object входит в
offline signing scope: изменение committee, threshold, key или срока после
ceremony ломает signatures.

## Apply rules

`POST /admin/authority/recovery` доступен только когда:

1. admin API аутентифицирован;
2. control plane уже находится в sticky Safe Mode;
3. configured public recovery policy доступна;
4. offline threshold валиден;
5. recovery покрывает highest locally observed authority epoch;
6. replacement epoch строго увеличивается.

После atomic persistence replacement authority становится effective state.
Только затем `NetworkViewGuard.apply_recovery_checkpoint` снимает freeze.
Следующий normal AuthorityCheckpoint обязан ссылаться на replacement hash и
подписываться уже новым authority quorum.

## Ограничения v1

- ceremony доставляется оператором отдельно на каждый Discovery; автоматический
  recovery gossip намеренно не включён;
- при разных локально сохранённых malicious forks Emergency Root должна явно
  выбрать covered epoch и replacement; процедура требует отдельного runbook;
- компрометация recovery threshold остаётся catastrophic trust boundary;
- потеря normal authority и recovery threshold одновременно требует manual
  trust reset/new genesis.
