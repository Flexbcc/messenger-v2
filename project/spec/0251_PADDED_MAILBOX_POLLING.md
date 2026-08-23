# 0251 — Padded Mailbox Polling v1

Endpoint/Home выполняет polling по расписанию, а не только после push. В
privacy mode запрос задаёт один fixed `cell_size` и число slots `1..32`.
Storage всегда возвращает ровно это число объектов данного размера.
Дополнительно действует hard byte budget ответа (по умолчанию 1 MiB), поэтому
большой size class автоматически уменьшает допустимое число slots и не создаёт
дешёвую response-amplification атаку.

Реальные endpoint-encrypted cells занимают первые slots. Остальные заполняются
CSPRNG bytes с UUID того же формата и временными метками той же формы. Dummy не
маркируется в ответе: endpoint отличает его только по неуспешной AEAD-проверке.
Такие slots не ACK-аются. Для чтения разных size classes выполняются отдельные
одинаково расписанные polls.

`limit` применяется отдельно к каждой Storage replica. Quorum client отклоняет
ответ с большим числом slots, объединяет все уникальные hashes и не обрезает
результат повторно до `limit`: иначе dummy первой реплики мог бы вытеснить
реальную cell, сохранившуюся только на другой реплике. Итог всё равно bounded
как `limit × число настроенных replicas`.

В padded response `has_more=false`: после расшифрования и ACK реальных cells
endpoint выполняет следующий плановый fixed poll. Это не раскрывает размер
очереди полем continuation. Legacy непаддированный fetch сохранён только как
миграционный/диагностический path.

Padding скрывает приблизительный размер ответа от внешнего TLS-наблюдателя, но
не от самого Storage: он видит mailbox token query и число реальных DB rows.
Полная privacy требует периодического запроса и cover mailbox rotation на
endpoint. Ответ, HTTP headers и TLS framing могут давать небольшой residual
size signal, поэтому quantitative проверка обязательна.
