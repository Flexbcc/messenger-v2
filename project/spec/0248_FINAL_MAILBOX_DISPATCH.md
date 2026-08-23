# 0248 — Final Mailbox Dispatch v1

Последний onion layer destination Home раскрывает только:

- opaque 256-bit mailbox capability;
- endpoint-encrypted fixed-size cell;
- bounded Storage TTL.

Final mailbox cell ограничена классами 4/16/64 KiB: 256 KiB cell невозможно
корректно вложить в 256 KiB onion packet вместе с transport overhead. Более
крупные контейнеры должны предварительно агрегироваться/кодироваться shards.

Home не преобразует payload в Message, не получает UserID/conversation ID и не
расшифровывает cell. Она записывает cell через replicated
`OpaqueMailboxClient`; успешным final dispatch считается только достижение
Storage write quorum. Ошибка возвращает dispatch в Mix Pool до исходного expiry.

Home-only role отклоняет transit next-hop result. Таким образом Relay и Home
имеют разные runtime capabilities даже при общем `MixIngressRuntime`.
